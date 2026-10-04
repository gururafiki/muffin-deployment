-- The symbol map is rebuilt by whoever changes what it is built from, and the Track button does it
-- inline.
--
-- WHY. `market.symbol_security` resolves a symbol to a security for every chart, and it is a
-- materialized view, so a security nobody refreshed it for has no chart. Since migration
-- 20261004140000 the Dagster asset `symbol_security` refreshes it after the three assets that
-- write its inputs, and `promote_listing` (the Track button), the one writer outside Dagster,
-- refreshes it itself.
--
--   1. a security tracked by hand resolves through the map at once, with no other refresh;
--   2. a symbol written any other way waits for `refresh_symbol_map`, which rebuilds the map and
--      reports what it holds — so the map is a snapshot and (1) proves the Track button refreshed;
--   3. only the worker may call `refresh_symbol_map`.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZD', 'Mapland', 'ZD', false)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix, preference) values ('T2D', 'ZD', '.ZD', 1)
on conflict (exch_code) do nothing;
insert into market.venue_listing (figi, composite_figi, exch_code, ticker, name, provider_symbol, last_seen_at)
values ('BBGT2D0001', 'BBGT2D0001', 'T2D', 'TDA', 'T2D tracked by hand', 'TDA.ZD', now());

-- THE MAP IS A SNAPSHOT, so start from a known one.
refresh materialized view market.symbol_security;

-- 1. The Track button's security resolves at once.
set local request.jwt.claims = '{"sub":"admin-x","app_metadata":{"role":"admin"}}';
do $$
declare r jsonb;
begin
  r := market.promote_listing('BBGT2D0001');
  if not (r ->> 'promoted' = 'true') then
    raise exception 'the fixture line was not promoted, so nothing below means anything: %', r;
  end if;
  if not exists (select 1 from market.symbol_security where symbol = 'TDA.ZD') then
    raise exception 'a security tracked by hand does not resolve until something else refreshes the map';
  end if;
end $$;

-- 2. Written any other way, a symbol waits for the refresh, which reports what the map holds.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-0000000002d2', 'T2D written by a lane', 'equity', 'ZD');
insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-0000000002d2', 'yfinance', 'TDB.ZD');
do $$
declare r jsonb;
begin
  if exists (select 1 from market.symbol_security where symbol = 'TDB.ZD') then
    raise exception 'the map is not a snapshot, so (1) proves nothing';
  end if;
  r := market.refresh_symbol_map();
  if not exists (select 1 from market.symbol_security where symbol = 'TDB.ZD') then
    raise exception 'refresh_symbol_map did not rebuild the map';
  end if;
  if (r ->> 'rows')::bigint is distinct from (select count(*) from market.symbol_security) then
    raise exception 'refresh_symbol_map reported % rows, the map holds %',
      r ->> 'rows', (select count(*) from market.symbol_security);
  end if;
  if r ->> 'duration_ms' is null then
    raise exception 'refresh_symbol_map reported no duration, so its walk toward a ceiling is invisible';
  end if;
end $$;

-- 3. Only the worker refreshes it.
do $$
begin
  if not has_function_privilege('ingest_rw', 'market.refresh_symbol_map()', 'EXECUTE') then
    raise exception 'ingest_rw cannot refresh the symbol map';
  end if;
  if has_function_privilege('anon', 'market.refresh_symbol_map()', 'EXECUTE') then
    raise exception 'anon can refresh the symbol map';
  end if;
end $$;

rollback;
