-- SEC's map is keyed on the symbol a company TRADES under, which is not the one OpenFIGI returns.
--
-- WHY THIS EXISTS AS A TEST. The failure is invisible to every count in the system. `sec-cik-map`
-- reports `{"filers": 10388, "updated": 0}` — a healthy run — while a security it cannot match
-- simply keeps a null CIK, and every SEC-gated resource then skips it in silence. Berkshire
-- Hathaway sat in exactly that state with a 12.46% fund weight: 0 filings, 0 segments, because
-- OpenFIGI spells its B share `BRK/B` and SEC spells it `BRK-B`.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. Four rules could be written here; three are
-- wrong, and a fixture missing the row that separates them would pass under all four:
--
--   * "join on the ticker identifier"             — the old rule. Misses Berkshire.        (row 2)
--   * "…or ANY listing symbol"                    — assigns a British company a US filer's
--                                                   CIK on a symbol collision.             (row 3)
--   * "…or any US listing symbol, min() on a tie" — invents an answer where there is none.  (row 4)
--   * "…refusing ties, ticker identifier first"   — what shipped.                           (row 5)
--
-- A WRONG CIK IS WORSE THAN NO CIK, which is why rows 3 and 4 assert SILENCE. A null CIK means a
-- security is skipped; a wrong one silently attributes another company's filings, statements and
-- segments to it, and every downstream number then looks populated and is fiction.
--
-- `market.listing` is keyed (security_id, exch_code), so the ambiguous security needs TWO US
-- venues rather than two rows on one. That is realistic — the catalogue carries a single `US` row
-- today and nothing stops it being split per venue — and it is also why the rule joins through
-- `market.exchange.country_iso2` instead of the literal `exch_code = 'US'`.

\set ON_ERROR_STOP on

begin;

-- Two US venues (SEC's population) and a foreign one, which must never be consulted.
insert into market.exchange (exch_code, country_iso2, suffix)
     values ('US', 'US', ''), ('UQ', 'US', ''), ('LN', 'GB', '.L')
on conflict (exch_code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  -- 1. An ordinary company: the ticker identifier matches SEC. The pre-existing path, unchanged.
  ('00000000-0000-0000-0000-000000188a01', 'T188 Ordinary Inc',   'equity'),
  -- 2. THE BERKSHIRE SHAPE. OpenFIGI's spelling is not in SEC's map; the US listing's is.
  ('00000000-0000-0000-0000-000000188a02', 'T188 Dual Class Inc', 'equity'),
  -- 3. A British company whose LONDON symbol collides with an unrelated US ticker. Must stay null.
  ('00000000-0000-0000-0000-000000188a03', 'T188 British plc',    'equity'),
  -- 4. Two US listings resolving to two different CIKs. Ambiguous: must stay null.
  ('00000000-0000-0000-0000-000000188a04', 'T188 Ambiguous Inc',  'equity'),
  -- 5. Ticker identifier AND US listing both match, but to DIFFERENT CIKs. The identifier wins,
  --    which is what makes the widening strictly additive rather than a silent re-assignment.
  ('00000000-0000-0000-0000-000000188a05', 'T188 Precedence Inc', 'equity')
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000188a01', 'ticker', 'T188ORD'),
  -- The Bloomberg spelling. Deliberately absent from the map below.
  ('00000000-0000-0000-0000-000000188a02', 'ticker', 'T188/B'),
  ('00000000-0000-0000-0000-000000188a05', 'ticker', 'T188PRE')
on conflict (kind_code, value) do nothing;

insert into market.listing (security_id, exch_code, symbol, is_primary) values
  ('00000000-0000-0000-0000-000000188a01', 'US', 'T188ORD', true),
  -- The symbol the market actually uses, and the one SEC knows.
  ('00000000-0000-0000-0000-000000188a02', 'US', 'T188-B',  true),
  -- London only. Its bare symbol IS in the map, belonging to someone else entirely.
  ('00000000-0000-0000-0000-000000188a03', 'LN', 'T188COL', true),
  -- Two US venues, two symbols, two different filers.
  ('00000000-0000-0000-0000-000000188a04', 'US', 'T188AMA', true),
  ('00000000-0000-0000-0000-000000188a04', 'UQ', 'T188AMB', false),
  ('00000000-0000-0000-0000-000000188a05', 'US', 'T188ALT', false)
on conflict (security_id, exch_code) do nothing;

do $$
declare
  v_updated  integer;
  v_ordinary integer;
  v_dual     integer;
  v_british  integer;
  v_ambig    integer;
  v_prec     integer;
begin
  select market.apply_cik_map(jsonb_build_object(
    'T188ORD', 188001,   -- row 1, via the ticker identifier
    'T188-B',  188002,   -- row 2, via the US listing symbol ONLY
    'T188COL', 188003,   -- row 3's London symbol — belongs to an unrelated US filer
    'T188AMA', 188004,   -- row 4, rival A
    'T188AMB', 188007,   -- row 4, rival B — a different company
    'T188PRE', 188005,   -- row 5, via the ticker identifier
    'T188ALT', 188006    -- row 5, via the US listing — must LOSE to the identifier
  )) into v_updated;

  select cik into v_ordinary from market.security where security_id = '00000000-0000-0000-0000-000000188a01';
  select cik into v_dual     from market.security where security_id = '00000000-0000-0000-0000-000000188a02';
  select cik into v_british  from market.security where security_id = '00000000-0000-0000-0000-000000188a03';
  select cik into v_ambig    from market.security where security_id = '00000000-0000-0000-0000-000000188a04';
  select cik into v_prec     from market.security where security_id = '00000000-0000-0000-0000-000000188a05';

  if v_ordinary is distinct from 188001 then
    raise exception 'a security whose TICKER IDENTIFIER is in SEC''s map did not get its CIK '
                    '(got %) — the widening has broken the path that already worked for 3,516 '
                    'securities', coalesce(v_ordinary::text, 'null');
  end if;

  if v_dual is distinct from 188002 then
    raise exception 'the Berkshire shape did not resolve (got %) — OpenFIGI spells the B share '
                    'BRK/B and SEC spells it BRK-B, so a map joined only to security_identifier '
                    'leaves a 12.46%% holding with no filings and no segments',
                    coalesce(v_dual::text, 'null');
  end if;

  if v_british is not null then
    raise exception 'a LONDON-listed company was assigned CIK % from a symbol collision — SEC''s '
                    'map covers US registrants, so consulting a foreign venue attributes another '
                    'company''s filings, and a wrong CIK is worse than none', v_british;
  end if;

  if v_ambig is not null then
    raise exception 'two US listings resolving to two different CIKs produced % — that is not a '
                    'tie to break with min(), it means we cannot say which company this is',
                    v_ambig;
  end if;

  if v_prec is distinct from 188005 then
    raise exception 'the US listing symbol overruled the ticker identifier (got %, wanted 188005) '
                    '— the fallback must be consulted ONLY when the identifier matched nothing, or '
                    'the widening silently re-assigns CIKs that are already correct',
                    coalesce(v_prec::text, 'null');
  end if;

  -- Idempotence: a re-apply must change nothing, or a resource that runs on a TTL pays the WAL
  -- cost of a full table update every time for no reason.
  select market.apply_cik_map(jsonb_build_object('T188ORD', 188001, 'T188-B', 188002)) into v_updated;
  if v_updated <> 0 then
    raise exception 're-applying an unchanged map updated % rows — the "is distinct from" guard is '
                    'gone and every run now rewrites every matched security', v_updated;
  end if;

  raise notice 'ok  the CIK map meets the verified symbol, refuses collisions and ties, and the '
               'ticker identifier still wins';
end $$;

rollback;
