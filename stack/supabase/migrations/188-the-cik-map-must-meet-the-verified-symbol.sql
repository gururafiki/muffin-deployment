-- BERKSHIRE HATHAWAY HAS NO CIK BECAUSE OF ONE CHARACTER, AND NOTHING COULD REPORT IT.
--
-- `apply_cik_map` joins SEC's ticker -> CIK map to `security_identifier` where `kind_code =
-- 'ticker'`. That identifier is OpenFIGI's US lookup, and OpenFIGI spells Berkshire's B share the
-- Bloomberg way:
--
--     security_identifier.ticker : BRK/B      <- what the join asks with
--     listing.symbol             : BRK-B      <- verified against the provider
--     SEC's map                  : BRK-B  ->  1067983
--
-- So the join misses, `security.cik` stays null, and every SEC-gated resource skips the security
-- silently: `pending_segments` requires a CIK, so do the SEC statement path, `security-xbrl` and
-- the submissions filing history. Measured 2026-09-06 — Berkshire holds **0 filings and 0
-- segments** while carrying a **12.46% fund weight**, the heaviest security in the universe with
-- no SEC data at all. `sec-cik-map` reported `{"filers": 10388, "updated": 0}` throughout: it was
-- working perfectly and asking with the wrong spelling.
--
-- CLAUDE.md already records both halves of this and they had never been put together. `BRK/B` is
-- named as a symbol that "400s and takes its whole batch of 20 with it", and migration 039
-- established that a security's ticker identifier and its listing symbol are DIFFERENT ANSWERS TO
-- DIFFERENT QUESTIONS — the ticker is OpenFIGI's US lookup, the listing symbol is what
-- `security-symbol-repair` proved the provider accepts. SEC wants the one people trade under.
--
-- WHAT THIS IS WORTH, measured against SEC's real 10,412-entry map rather than estimated. Of 253
-- equities that have a US listing and no CIK, exactly **one** gains a CIK from the widening, with
-- no ambiguity and no collisions: Berkshire. I costed this at 122 and then at 15 before measuring
-- it properly; both were wrong, and the honest number is 1. It is still worth shipping, because
-- the one is a 12.46% holding — but the ratio is the lesson, not the fix.
--
-- THE WIDENING IS STRICTLY ADDITIVE, BY CONSTRUCTION. The listing symbol is consulted only for a
-- security whose ticker identifier matched nothing, so every CIK the current function resolves is
-- resolved identically. This is deliberate: it cannot regress the 3,516 securities that already
-- have one, and a change that can only add is a change that needs no backfill audit.
--
-- TWO GUARDS THAT MUST NOT BE DROPPED:
--
--   * ONLY US VENUES. SEC's map covers US registrants, so a foreign venue's symbol colliding with
--     an unrelated US ticker would assign a confidently wrong CIK — and a wrong CIK is worse than
--     none, since it silently attributes another company's filings, statements and segments. The
--     test is the VENUE'S COUNTRY through `market.exchange`, never the shape of the symbol
--     (`security-symbol-repair` records why pattern-matching a ticker rewrites working ones) and
--     never the literal `exch_code = 'US'`, which is one row today and may be split per venue.
--   * REFUSE AN AMBIGUOUS MATCH. Two US listings whose symbols resolve to two different CIKs is
--     not a tie to be broken by `min()`; it means we cannot say which company this is. Zero
--     securities are in that state today, which is exactly when a guard is cheap to add.

create or replace function market.apply_cik_map(p_map jsonb)
returns integer
language plpgsql
as $$
declare
  v_updated integer := 0;
begin
  if p_map is null or jsonb_typeof(p_map) <> 'object' then
    raise exception 'apply_cik_map expects a json object of ticker -> cik';
  end if;

  with pairs as (
    select upper(key) as ticker, (value #>> '{}')::integer as cik
      from jsonb_each(p_map)
     -- A ticker whose value is not a number is a malformed entry, not a filer. Rejecting it here
     -- keeps one bad row from aborting the statement — migrations and this function alike apply
     -- in a single transaction.
     where jsonb_typeof(value) = 'number'
  ),
  -- Every symbol a security may legitimately be keyed on, each carrying its precedence.
  candidates as (
    -- 1. The ticker identifier. What the function has always used; unchanged.
    select i.security_id, p.cik, 1 as precedence
      from market.security_identifier i
      join pairs p on p.ticker = upper(i.value)
     where i.kind_code = 'ticker'
    union all
    -- 2. The symbol a US venue actually lists the security under. Consulted only as a fallback.
    select l.security_id, p.cik, 2 as precedence
      from market.listing l
      join market.exchange e on e.exch_code = l.exch_code
      join pairs p on p.ticker = upper(l.symbol)
     where l.symbol is not null
       and e.country_iso2 = 'US'
  ),
  -- The best available precedence per security: a ticker match is never overruled by a listing.
  best as (
    select security_id, min(precedence) as precedence
      from candidates
     group by security_id
  ),
  resolved as (
    select c.security_id,
           min(c.cik)            as cik,
           count(distinct c.cik) as rivals
      from candidates c
      join best b
        on b.security_id = c.security_id
       and b.precedence  = c.precedence
     group by c.security_id
  )
  update market.security s
     set cik = r.cik
    from resolved r
   where r.security_id = s.security_id
     -- Two symbols pointing at two different companies is not a tie-break, it is a refusal.
     and r.rivals = 1
     -- IDEMPOTENT AND CHEAP TO RE-RUN. Without this every invocation rewrites every matched row,
     -- which is the WAL cost of a full table update on a resource that runs monthly for nothing.
     and s.cik is distinct from r.cik;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

comment on function market.apply_cik_map(jsonb) is
  'Applies SEC''s ticker -> CIK map in ONE statement, keyed on the ticker identifier and falling back to a US listing symbol. The fallback exists because OpenFIGI spells Berkshire''s B share BRK/B while SEC and the market spell it BRK-B, which left a 12.46% holding with no SEC filings or segments at all. Only US venues are consulted and an ambiguous match is refused: a wrong CIK silently attributes another company''s filings.';

revoke execute on function market.apply_cik_map(jsonb) from public;
grant execute on function market.apply_cik_map(jsonb) to service_role;

notify pgrst, 'reload schema';
