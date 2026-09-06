-- INDIA SHIPPED ASKING NSE WITH A VENDOR ABBREVIATION, AND NSE ANSWERS THAT WITH AN EMPTY 200.
--
-- Migration 185 built `pending_in_history` on `market.listing.symbol`, on the strength of a
-- planning probe against RELIANCE, HDFCBANK and INFY — three symbols that happen to match NSE's
-- own. Measured 2026-09-06 against NSE's published equity list, only **239 of 645** Indian
-- equities carry a listing symbol NSE recognises. The other 406 hold a vendor abbreviation:
--
--     SUEL -> SUZLON       HUVR -> HINDUNILVR    MSIL -> MARUTI
--     BAF  -> BAJFINANCE   KMB  -> KOTAKBANK     HNDL -> HINDALCO
--
-- Confirmed directly against the provider: `SUEL` returns 0 results and `SUZLON` returns 39;
-- `HUVR` 0 and `HINDUNILVR` 38. NSE answers an unknown symbol with an EMPTY ARRAY and HTTP 200,
-- so `in-filings` reported `walked: 6, mapped: 0, failed: 0` with no error anywhere — a resource
-- succeeding at asking the wrong question, which no count in the system could show.
--
-- This is the file's own oldest rule (probe an endpoint with symbols you expect to FAIL, not the
-- obvious mega-caps) broken while implementing the feature that rule exists to protect. It is also
-- the fourth time a symbol has been the deciding factor in a resource, after the OTC
-- foreign-ordinary line, `BRK/B` vs `BRK-B`, and the Bloomberg `*`/`/` spellings.
--
-- THE FIX IS A JOIN ON ISIN, WHICH NSE PUBLISHES ITSELF. `EQUITY_L.csv` is keyless, 2,570 rows,
-- and — measured, not assumed — carries **2,570 DISTINCT ISINs with no blanks and no ISIN mapping
-- to two symbols**, which is what makes it a safe key. It recovers 389 of the 406, taking India
-- from 37% to **97%**. The remaining 17 are securities NSE does not list.
--
-- The resolved symbol lands in `security_filer.filer_id`, which already exists and is already the
-- thing `in-filings` writes — so the backlog stops reading `listing.symbol` directly and reads the
-- resolved id when there is one. `listing.symbol` remains the fallback so a security NSE has not
-- listed is still attempted rather than silently dropped.

create or replace function market.apply_nse_symbol_map(p_map jsonb)
returns integer
language plpgsql
as $$
declare
  v_updated integer := 0;
begin
  if p_map is null or jsonb_typeof(p_map) <> 'object' then
    raise exception 'apply_nse_symbol_map expects a json object of isin -> nse symbol';
  end if;

  with pairs as (
    select upper(key) as isin, (value #>> '{}') as symbol
      from jsonb_each(p_map)
     -- A non-string value is a malformed entry, not a listing. Rejecting it here keeps one bad row
     -- from aborting the statement, which applies in a single transaction.
     where jsonb_typeof(value) = 'string'
       and length(value #>> '{}') > 0
  ),
  resolved as (
    select i.security_id, min(p.symbol) as symbol, count(distinct p.symbol) as rivals
      from market.security_identifier i
      join pairs p on p.isin = upper(i.value)
      join market.security s on s.security_id = i.security_id
     where i.kind_code = 'isin'
       -- SCOPED TO INDIA. An ISIN is globally unique, so this cannot currently mis-hit — but NSE
       -- lists only Indian companies, and a filer id is per (security, regulator): writing one for
       -- a security in another jurisdiction would advertise a filing route that does not exist.
       and s.country_iso2 = 'IN'
     group by i.security_id
  )
  insert into market.security_filer (security_id, source_code, filer_id, as_of)
  select r.security_id, 'nse', r.symbol, now()
    from resolved r
   -- Two symbols for one ISIN is not a tie to break with min(); NSE's list has none today, which
   -- is exactly when this costs nothing to assert.
   where r.rivals = 1
  on conflict (security_id, source_code) do update
    set filer_id = excluded.filer_id,
        as_of    = excluded.as_of
    -- IDEMPOTENT. Without this every run rewrites every row, and `history_walked_at` lives on this
    -- table — an unnecessary update is WAL for nothing on a resource that runs on a TTL.
    where market.security_filer.filer_id is distinct from excluded.filer_id;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

comment on function market.apply_nse_symbol_map(jsonb) is
  'Applies NSE''s published ISIN -> trading-symbol map in ONE statement. Exists because market.listing.symbol holds a vendor abbreviation for 406 of 645 Indian equities (SUEL for SUZLON, HUVR for HINDUNILVR), and NSE answers an unknown symbol with an empty 200 — so the resource reported success while asking the wrong question.';

revoke execute on function market.apply_nse_symbol_map(jsonb) from public;
grant execute on function market.apply_nse_symbol_map(jsonb) to service_role;

-- ── the backlog must ask with the RESOLVED symbol ───────────────────────────────────────────────
drop view if exists market.pending_in_history;
create view market.pending_in_history as
select s.security_id,
       -- THE RESOLVED NSE SYMBOL WINS; the listing symbol is the fallback, so a security NSE has
       -- not listed is still attempted rather than silently dropped from the queue.
       coalesce(sf.filer_id, l.symbol) as symbol,
       coalesce(max(h.weight), 0::numeric) as best_weight
  from market.security s
  join market.listing l on l.security_id = s.security_id
  join market.exchange e on e.exch_code = l.exch_code
  left join market.security_filer sf
    on sf.security_id = s.security_id and sf.source_code = 'nse'
  left join market.fund_holding_current h on h.security_id = s.security_id
 where s.security_type_code = 'equity'
   and s.country_iso2 = 'IN'
   and e.country_iso2 = 'IN'
   and l.symbol is not null
   and (sf.history_walked_at is null or sf.history_walked_at < now() - interval '90 days')
 group by s.security_id, sf.filer_id, l.symbol
 order by coalesce(max(h.weight), 0::numeric) desc, coalesce(sf.filer_id, l.symbol);

comment on view market.pending_in_history is
  'Indian equities whose NSE filing history has not been walked in 90 days. `symbol` is the RESOLVED NSE trading symbol from security_filer.filer_id where one is known, falling back to market.listing.symbol — which holds a vendor abbreviation for 406 of 645 Indian equities and makes NSE answer with an empty 200.';

-- A DROP TAKES THE GRANTS WITH IT, and superuser cannot see that (migration 189, same week).
grant select on market.pending_in_history to service_role;

-- ── schedule it ─────────────────────────────────────────────────────────────────────────────────
-- A RESOURCE THAT IS NEVER INVOKED CANNOT FAIL. `exchange-listings` was written, deployed,
-- reachable and absent from the cron for weeks; the guard that catches that reads this table.
-- Placed immediately BEFORE in-filings, because the map is what makes the walk ask correctly.
-- The (position, resource) form is the one every other migration uses AND the one logic-check's
-- scheduling guard parses. A second spelling would be a vocabulary carried in two places, which
-- this schema has been bitten by repeatedly — and here it would read as scheduled while the guard
-- reported it absent. `enabled` defaults to true.
insert into market.cron_resource (position, resource) values
  (425, 'in-symbols')
on conflict (position) do update set resource = excluded.resource;

notify pgrst, 'reload schema';
