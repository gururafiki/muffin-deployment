-- A tracked security's listings are derived from the directory, with one primary line each.
--
-- WHY THIS EXISTS. `market.listing` was written only by edge functions that retired on
-- 2026-09-26, and it supplies 11,547 securities' currency and the display symbol. Its replacement,
-- `security_listing`, is a join the database can answer: the directory lines of each tracked share
-- class. Migration 20260927000000 answers it in `market.derive_security_listing()`.
--
-- Each fixture makes one rule the only thing deciding its answer:
--
--   T927 held symbol      the held yfinance symbol names a FOREIGN line; it beats both the legacy
--                         primary venue and the home venue
--   T927 spelled apart    the held symbol is `TN-B.ZA`, the directory says `TN/B.ZA` on the
--                         second-preference venue; only `symbol_match_key` finds it, and without
--                         it the home venue picks the other line
--   T927 legacy venue     no held symbol; the legacy primary is abroad, and beats the home venue
--   T927 home venue       no held symbol, no legacy; preference 1 wins, although the other home
--                         line has the lower FIGI and the foreign line the shorter ticker
--   T927 abroad only      nothing places it, so it gets NO primary, not an arbitrary line
--   T927 currency         carried to the line the legacy row names, to the only line on a venue,
--                         and to no other line; never overwritten once set
--   T927 moves primary    a new held symbol moves the flag; the demote runs before the promote
--   T927 class moves      a line whose class moves to a security that already has a primary
--                         arrives there NOT primary, or the unique index refuses the move
--   T927 retracted        a line the directory stops attributing to a tracked class is removed
--
-- And: a second run writes nothing, `anon` cannot call it, and `ingest_rw` can.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.identifier_kind (code, name, is_global_unique)
values ('share_class_figi', 'OpenFIGI share-class FIGI', true) on conflict do nothing;
insert into market.data_source (code, name) values ('yfinance', 'yfinance'), ('openfigi', 'OpenFIGI')
on conflict do nothing;
insert into market.currency (code) values ('ZUA'), ('ZFA'), ('EUR') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('ZU', 'Homeland', 'ZU', false), ('ZX', 'Abroadia', 'ZX', false)
on conflict (iso2) do nothing;
-- Two home venues sharing a suffix, as AT and AU share `.AX`, and one abroad.
insert into market.exchange (exch_code, country_iso2, suffix, preference) values
  ('T9A', 'ZU', '.ZA', 1), ('T9B', 'ZU', '.ZA', 2), ('T9F', 'ZX', '.ZF', 1)
on conflict (exch_code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000927a01', 'T927 held symbol',     'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000927a02', 'T927 spelled apart',   'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000927a03', 'T927 legacy venue',    'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000927a04', 'T927 home venue',      'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000927a05', 'T927 abroad only',     'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000927a06', 'T927 currency',        'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000927a07', 'T927 moves primary',   'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000927a08', 'T927 class moves from', 'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000927a09', 'T927 class moves to',  'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000927a10', 'T927 retracted',       'equity', 'ZU');

insert into market.security_identifier (kind_code, value, security_id) values
  ('share_class_figi', 'T927CLS01', '00000000-0000-0000-0000-000000927a01'),
  ('share_class_figi', 'T927CLS02', '00000000-0000-0000-0000-000000927a02'),
  ('share_class_figi', 'T927CLS03', '00000000-0000-0000-0000-000000927a03'),
  ('share_class_figi', 'T927CLS04', '00000000-0000-0000-0000-000000927a04'),
  ('share_class_figi', 'T927CLS05', '00000000-0000-0000-0000-000000927a05'),
  ('share_class_figi', 'T927CLS06', '00000000-0000-0000-0000-000000927a06'),
  ('share_class_figi', 'T927CLS07', '00000000-0000-0000-0000-000000927a07'),
  ('share_class_figi', 'T927CLS08', '00000000-0000-0000-0000-000000927a08'),
  ('share_class_figi', 'T927CLS09', '00000000-0000-0000-0000-000000927a09'),
  ('share_class_figi', 'T927CLS10', '00000000-0000-0000-0000-000000927a10');

insert into market.venue_listing (figi, exch_code, ticker, provider_symbol, share_class_figi) values
  ('BBGT927A1', 'T9A', 'TA',   'TA.ZA',   'T927CLS01'),
  ('BBGT927A2', 'T9F', 'TAF',  'TAF.ZF',  'T927CLS01'),
  ('BBGT927N1', 'T9B', 'TN/B', 'TN/B.ZA', 'T927CLS02'),
  ('BBGT927N2', 'T9A', 'TNC',  'TNC.ZA',  'T927CLS02'),
  ('BBGT927B1', 'T9A', 'TB',   'TB.ZA',   'T927CLS03'),
  ('BBGT927B2', 'T9F', 'TBF',  'TBF.ZF',  'T927CLS03'),
  ('BBGT927C1', 'T9B', 'TC',   'TC.ZA',   'T927CLS04'),
  ('BBGT927C2', 'T9A', 'TC',   'TC.ZA',   'T927CLS04'),
  ('BBGT927C0', 'T9F', 'C',    'C.ZF',    'T927CLS04'),
  ('BBGT927D1', 'T9F', 'TD',   'TD.ZF',   'T927CLS05'),
  ('BBGT927E1', 'T9A', 'TE',   'TE.ZA',   'T927CLS06'),
  ('BBGT927E2', 'T9A', 'TEX',  'TEX.ZA',  'T927CLS06'),
  ('BBGT927E3', 'T9F', 'TE',   'TE.ZF',   'T927CLS06'),
  ('BBGT927H1', 'T9A', 'TH',   'TH.ZA',   'T927CLS07'),
  ('BBGT927H2', 'T9A', 'THB',  'THB.ZA',  'T927CLS07'),
  ('BBGT927MX', 'T9A', 'TMX',  'TMX.ZA',  'T927CLS08'),
  ('BBGT927MY', 'T9A', 'TMY',  'TMY.ZA',  'T927CLS09'),
  ('BBGT927F1', 'T9A', 'TF',   'TF.ZA',   'T927CLS10');

insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-000000927a01', 'yfinance', 'TAF.ZF'),
  ('00000000-0000-0000-0000-000000927a02', 'yfinance', 'TN-B.ZA');

-- The legacy table: one row per (security, venue).
insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code, currency_code) values
  ('00000000-0000-0000-0000-000000927a01', 'T9A', 'TA',   'TA.ZA',   true,  'openfigi', 'ZUA'),
  ('00000000-0000-0000-0000-000000927a03', 'T9F', 'TBF',  'TBF.ZF',  true,  'openfigi', 'ZFA'),
  -- names E1 by symbol, so E2 on the same venue must not inherit it
  ('00000000-0000-0000-0000-000000927a06', 'T9A', 'TE',   'TE.ZA',   true,  'openfigi', 'ZUA'),
  -- a stale symbol, but E3 is the security's only line on the venue
  ('00000000-0000-0000-0000-000000927a06', 'T9F', 'OLDE', 'OLDE.ZF', false, 'openfigi', 'ZFA');

-- A primary per security, as one row each, for the assertions below.
create temp view t927_primary as
select s.name, sl.figi
  from market.security s
  left join market.security_listing sl on sl.security_id = s.security_id and sl.is_primary
 where s.name like 'T927 %';

-- 0. The matching key, on the spellings measured in production.
do $$
begin
  if market.symbol_match_key('GETI-B.ST') <> market.symbol_match_key('GETIB.ST')
     or market.symbol_match_key('BBL-F.BK') <> market.symbol_match_key('BBL/F.BK')
     or market.symbol_match_key('VESTA.MX') <> market.symbol_match_key('VESTA*.MX')
     or market.symbol_match_key('BRK-B') <> market.symbol_match_key('BRK/B')
     or market.symbol_match_key('0586.HK') <> market.symbol_match_key('586.HK') then
    raise exception 'two spellings of one line got different keys: % % % % %',
      market.symbol_match_key('GETI-B.ST'), market.symbol_match_key('BBL/F.BK'),
      market.symbol_match_key('VESTA*.MX'), market.symbol_match_key('BRK/B'),
      market.symbol_match_key('0586.HK');
  end if;
  if market.symbol_match_key('BMA') = market.symbol_match_key('BMAD')
     or market.symbol_match_key('586.HK') = market.symbol_match_key('586.KS')
     or market.symbol_match_key('0586.HK') = market.symbol_match_key('5860.HK') then
    raise exception 'two different lines share a key — the venue or a significant digit was dropped';
  end if;
  raise notice 'ok  a line''s two spellings share a key; different lines do not';
end $$;

-- 1. The first run, as the worker.
do $$
declare
  r jsonb;
  bad text;
begin
  set local role ingest_rw;
  r := market.derive_security_listing();
  reset role;

  if (r->>'inserted')::int <> 18 then
    raise exception 'expected 18 lines stored, got %', r;
  end if;

  select string_agg(format('%s -> %s', name, coalesce(figi, 'none')), '; ' order by name) into bad
    from t927_primary
   where (name, coalesce(figi, 'none')) not in (
     ('T927 held symbol',      'BBGT927A2'),
     ('T927 spelled apart',    'BBGT927N1'),
     ('T927 legacy venue',     'BBGT927B2'),
     ('T927 home venue',       'BBGT927C2'),
     ('T927 abroad only',      'none'),
     ('T927 currency',         'BBGT927E1'),
     ('T927 moves primary',    'BBGT927H1'),
     ('T927 class moves from', 'BBGT927MX'),
     ('T927 class moves to',   'BBGT927MY'),
     ('T927 retracted',        'BBGT927F1'));
  if bad is not null then
    raise exception 'wrong primary line: %', bad;
  end if;
  raise notice 'ok  the primary is the line we price, then the legacy venue, then the home venue, else none';

  select string_agg(format('%s=%s', figi, coalesce(currency_code, 'null')), ' ' order by figi) into bad
    from market.security_listing
   where figi in ('BBGT927E1', 'BBGT927E2', 'BBGT927E3')
     and (figi, coalesce(currency_code, 'null')) not in
         (('BBGT927E1', 'ZUA'), ('BBGT927E2', 'null'), ('BBGT927E3', 'ZFA'));
  if bad is not null then
    raise exception 'a currency went to the wrong line: %', bad;
  end if;
  raise notice 'ok  a currency goes to the line its legacy row names, or the only line on the venue';
end $$;

-- 2. A second run writes nothing.
do $$
declare r jsonb;
begin
  r := market.derive_security_listing();
  if (r->>'inserted')::int + (r->>'changed')::int + (r->>'retracted')::int
     + (r->>'primaries_promoted')::int + (r->>'primaries_demoted')::int <> 0 then
    raise exception 'a run over unchanged inputs rewrote rows: %', r;
  end if;
  raise notice 'ok  a second run over unchanged inputs writes nothing';
end $$;

-- 3. A currency, once set, is kept — even when the row is rewritten for another reason.
update market.security_listing set currency_code = 'EUR' where figi = 'BBGT927E1';
update market.venue_listing set last_seen_at = now() + interval '1 day' where figi = 'BBGT927E1';

-- 4. The flag moves, a class moves, a line is retracted.
insert into market.security_provider_symbol (security_id, provider_code, symbol)
values ('00000000-0000-0000-0000-000000927a07', 'yfinance', 'THB.ZA');
update market.security_identifier set security_id = '00000000-0000-0000-0000-000000927a09'
 where kind_code = 'share_class_figi' and value = 'T927CLS08';
update market.venue_listing set share_class_figi = null where figi = 'BBGT927F1';

do $$
declare
  r jsonb;
  c text;
  n integer;
begin
  r := market.derive_security_listing();

  select currency_code into c from market.security_listing where figi = 'BBGT927E1';
  if c is distinct from 'EUR' then
    raise exception 'a stored currency was overwritten (EUR became %)', c;
  end if;
  raise notice 'ok  a currency, once set, is never overwritten';

  select figi into c from t927_primary where name = 'T927 moves primary';
  if c is distinct from 'BBGT927H2' then
    raise exception 'a new held symbol did not move the primary (still %)', c;
  end if;

  select count(*) into n from market.security_listing
   where security_id = '00000000-0000-0000-0000-000000927a09' and is_primary;
  if n <> 1 then
    raise exception 'the security a class moved to has % primaries', n;
  end if;
  select count(*) into n from market.security_listing
   where security_id = '00000000-0000-0000-0000-000000927a08';
  if n <> 0 then
    raise exception 'the security a class moved from kept % listing(s)', n;
  end if;
  raise notice 'ok  a moved class arrives without its flag, and the flag moves without a conflict';

  if exists (select 1 from market.security_listing where figi = 'BBGT927F1') then
    raise exception 'a line the directory no longer attributes to a tracked class was kept: %', r;
  end if;
  raise notice 'ok  a line the directory no longer attributes is retracted';
end $$;

-- 5. Only the worker and the service role can call it.
do $$
begin
  if has_function_privilege('anon', 'market.derive_security_listing()', 'execute') then
    raise exception 'anon can call derive_security_listing — market is exposed through PostgREST';
  end if;
  if not has_function_privilege('ingest_rw', 'market.derive_security_listing()', 'execute') then
    raise exception 'ingest_rw cannot call derive_security_listing';
  end if;
  raise notice 'ok  the worker can derive listings, and anon cannot';
end $$;

rollback;
