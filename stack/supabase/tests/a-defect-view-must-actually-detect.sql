-- A DEFECT VIEW THAT NEVER FIRES IS A DASHBOARD PANEL, NOT A GUARD.
--
-- `market.data_defect` replaces ~15 hand-written PostgREST assertions in market-verify.yml, and it
-- is read by TWO consumers — the hourly sampler for trends, and market-verify AS ANON for the
-- nightly gate. Both would look perfectly healthy against a view that returns zero because its
-- predicates are wrong, rather than because the data is clean.
--
-- So each invariant is seeded with the EXACT defect it exists to catch, and asserted to move. The
-- values are not invented: they are the ones this pipeline actually produced.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.identifier_kind (code, name) values ('cusip','CUSIP'), ('isin','ISIN')
  on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-nport','N-PORT',200)
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZD','Defectland','ZD',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-0000000d0001','T134 One','equity','ZD')
on conflict (security_id) do nothing;

-- Baseline: whatever the fixtures already contain.
create temporary table before_ on commit drop as select defect, n from market.data_defect;

-- 1. THE PLACEHOLDER. `<cusip>000000000</cusip>` is SEC's "no CUSIP", carried by 72% of holdings.
--    Treated as a value it collapsed Accenture, Seagate, TE Connectivity and NXP into ONE security.
insert into market.security_identifier (kind_code, value, security_id, source_code)
values ('cusip','000000000','00000000-0000-0000-0000-0000000d0001','sec-nport')
on conflict do nothing;

-- 2. A FABRICATED TOTAL LOSS: a zero close made every period read exactly -100%.
insert into market.performance (scope, scope_id, period, change_pct, as_of, stale_after, source)
values ('instrument','T134-A','1y',-100, now(), now() + interval '1 day','test')
on conflict do nothing;

-- 3. A FROZEN SERIES — flat on THREE windows at once, which coincidence cannot reach. One or two
--    zeros are ordinary on a coarse tick grid (Tokyo, Shenzhen, Seoul); three is a dead feed.
insert into market.performance (scope, scope_id, period, change_pct, as_of, stale_after, source)
values ('instrument','T134-FROZEN','1d',0, now(), now() + interval '1 day','test'),
       ('instrument','T134-FROZEN','1w',0, now(), now() + interval '1 day','test'),
       ('instrument','T134-FROZEN','1m',0, now(), now() + interval '1 day','test')
on conflict do nothing;

do $$
declare
  moved text[] := '{}';
  r record;
begin
  for r in
    select a.defect, b.n as was, a.n as now_
      from market.data_defect a join before_ b using (defect)
     where a.n > b.n
  loop
    moved := moved || r.defect;
  end loop;

  if not ('placeholder_cusip' = any(moved)) then
    raise exception 'seeding the all-zero CUSIP did not move `placeholder_cusip` — the predicate '
                    'does not match the value SEC actually writes';
  end if;
  if not ('returns_at_minus_100' = any(moved)) then
    raise exception 'seeding a -100%% return did not move `returns_at_minus_100`';
  end if;
  if not ('frozen_series' = any(moved)) then
    raise exception 'a symbol flat on THREE fresh windows did not move `frozen_series`';
  end if;
  raise notice '  ok  three seeded defects each moved their own counter: %', moved;
end $$;

-- AND A SYMBOL FLAT ON ONLY TWO WINDOWS MUST NOT FIRE. Without this the check is just "count the
-- zeros", which is the version that cried wolf at 12 rows and called POST.VI, MING.OL and 2109.T
-- delisted while they were trading normally.
do $$
declare before_n bigint; after_n bigint;
begin
  select n into before_n from market.data_defect where defect = 'frozen_series';
  insert into market.performance (scope, scope_id, period, change_pct, as_of, stale_after, source)
  values ('instrument','T134-ROUNDTRIP','1d',0, now(), now() + interval '1 day','test'),
         ('instrument','T134-ROUNDTRIP','1w',0, now(), now() + interval '1 day','test')
  on conflict do nothing;
  select n into after_n from market.data_defect where defect = 'frozen_series';

  if after_n <> before_n then
    raise exception 'a symbol flat on TWO windows was reported as frozen (% -> %) — the check is '
                    'counting zeros rather than requiring three', before_n, after_n;
  end if;
  raise notice '  ok  two flat windows is a round-trip, not a frozen series — correctly ignored';
end $$;

-- THE BOUNDS ARE LOAD-BEARING. A control table nothing reads is decorative.
do $$
declare n_before bigint; n_after bigint;
begin
  select coalesce(sum(n),0) into n_before from market.metric_out_of_range;

  insert into market.metric (code, name, category, unit, is_derived, is_flow)
  values ('t134_ratio','T134 ratio','test','ratio',false,false) on conflict (code) do nothing;
  update market.metric set min_plausible = -1, max_plausible = 1 where code = 't134_ratio';
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, source_code)
  values ('00000000-0000-0000-0000-0000000d0001','t134_ratio','ttm', current_date, 42, 'sec-nport')
  on conflict do nothing;

  select coalesce(sum(n),0) into n_after from market.metric_out_of_range;
  if n_after <= n_before then
    raise exception 'a value of 42 against max_plausible = 1 was not reported (% -> %) — '
                    'market.metric bounds are decorative', n_before, n_after;
  end if;
  raise notice '  ok  a value outside the catalogue bounds is reported';

  -- And clearing the bound must clear the finding, or the bound is not what decides it.
  update market.metric set min_plausible = null, max_plausible = null where code = 't134_ratio';
  select coalesce(sum(n),0) into n_after from market.metric_out_of_range;
  if n_after <> n_before then
    raise exception 'clearing the bounds did not clear the finding — something other than '
                    'market.metric is deciding what is out of range';
  end if;
  raise notice '  ok  clearing the bound clears the finding — the control table decides';
end $$;


-- ── THE TWO FALSE POSITIVES THE FIRST PRODUCTION READ FOUND ───────────────────────────────────
--
-- Both of these predicates were WRONG when 134 shipped, and both would have failed market-verify
-- nightly on data that is correct. Each is asserted in the direction that was broken: the guard
-- must stay SILENT on the innocent shape. Asserting only that it fires on a real defect is what
-- let them through in the first place.

-- 6. A FLAT PRICE DOES NOT CONTRADICT A `performance_missing_at` MARK.
--    Migration 055's header predicted this exactly: a money-market line "has a bar every day and a
--    single distinct close forever, so it legitimately yields no return, earns its mark honestly".
--    Measured on the first read, 15 of 29 flagged securities were this shape. Holding BARS is not
--    evidence; holding bars that MOVE is.
insert into market.security (security_id, name, security_type_code, country_iso2, performance_missing_at)
values ('00000000-0000-0000-0000-0000000d0060','T134 Flat Money Market','equity','ZD', now() - interval '2 days')
on conflict (security_id) do nothing;
insert into market.security_price (security_id, date, close, grain) values
  ('00000000-0000-0000-0000-0000000d0060', current_date - 1, 100.00, 'daily'),
  ('00000000-0000-0000-0000-0000000d0060', current_date - 2, 100.00, 'daily'),
  ('00000000-0000-0000-0000-0000000d0060', current_date - 3, 100.00, 'daily')
on conflict do nothing;

do $$
declare n_flat bigint;
begin
  select n into n_flat from market.data_defect where defect = 'contradicted_negative_cache';
  if n_flat <> (select n from before_ where defect = 'contradicted_negative_cache') then
    raise exception 'a FLAT series (one distinct close) was reported as contradicting its mark — '
                    'this is migration 055''s GVMXX case and the mark is honest';
  end if;
end $$;

--    ...and a MOVING price must still fire, or the fix has simply disabled the check.
insert into market.security (security_id, name, security_type_code, country_iso2, performance_missing_at)
values ('00000000-0000-0000-0000-0000000d0061','T134 Moving And Marked','equity','ZD', now() - interval '2 days')
on conflict (security_id) do nothing;
insert into market.security_price (security_id, date, close, grain) values
  ('00000000-0000-0000-0000-0000000d0061', current_date - 1, 101.50, 'daily'),
  ('00000000-0000-0000-0000-0000000d0061', current_date - 2, 100.00, 'daily'),
  ('00000000-0000-0000-0000-0000000d0061', current_date - 3,  99.25, 'daily')
on conflict do nothing;

do $$
declare n_move bigint; base bigint;
begin
  select n into n_move from market.data_defect where defect = 'contradicted_negative_cache';
  select n into base   from before_ where defect = 'contradicted_negative_cache';
  if n_move <= base then
    raise exception 'a MOVING series under a `performance_missing_at` mark was not reported '
                    '(% -> %) — requiring the price to move has disabled the check entirely', base, n_move;
  end if;
end $$;

-- 7. A COUNTRY WHOSE SECURITIES HAVE TICKERS IS NOT "SILENTLY DROPPED".
--    The fetch key everywhere in this pipeline is `coalesce(provider_symbol, ticker)`. The first
--    read flagged Bermuda: 56 equities, no provider symbol, and ALL 56 carrying a ticker (NCLH,
--    ESNT, FLTLF). Perfectly fetchable. A country is only dropped when NOT ONE of its securities
--    is addressable by EITHER key — the Taiwan wipe this exists to catch.
insert into market.countries (iso2, name, flag, drillable) values ('ZT','Tickerland','ZT',false)
  on conflict (iso2) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;

do $$
declare i int; base bigint; after bigint; sid uuid;
begin
  select n into base from before_ where defect = 'country_with_no_symbols';
  -- 25 equities, no provider symbol, every one with a ticker.
  for i in 1..25 loop
    sid := ('00000000-0000-0000-0000-0000000e' || lpad(i::text, 4, '0'))::uuid;
    insert into market.security (security_id, name, security_type_code, country_iso2)
    values (sid, 'T134 Ticker Co ' || i, 'equity', 'ZT') on conflict (security_id) do nothing;
    insert into market.security_identifier (kind_code, value, security_id)
    values ('ticker', 'ZTK' || i, sid) on conflict (kind_code, value) do nothing;
  end loop;

  select n into after from market.data_defect where defect = 'country_with_no_symbols';
  if after <> base then
    raise exception 'a country whose every equity carries a TICKER was reported as having no '
                    'symbols (% -> %) — the fetch key is coalesce(provider_symbol, ticker)', base, after;
  end if;
end $$;

--    ...and a country with NEITHER key must still fire, or the check is decorative.
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Wipedland','ZW',false)
  on conflict (iso2) do nothing;
do $$
declare i int; base bigint; after bigint;
begin
  select n into base from before_ where defect = 'country_with_no_symbols';
  for i in 1..25 loop
    insert into market.security (security_id, name, security_type_code, country_iso2)
    values (('00000000-0000-0000-0000-0000000f' || lpad(i::text, 4, '0'))::uuid,
            'T134 Wiped Co ' || i, 'equity', 'ZW') on conflict (security_id) do nothing;
  end loop;
  select n into after from market.data_defect where defect = 'country_with_no_symbols';
  if after <= base then
    raise exception 'a country where NO equity has a provider symbol OR a ticker was not reported '
                    '(% -> %) — this is the Taiwan wipe the check exists for', base, after;
  end if;
end $$;

rollback;
