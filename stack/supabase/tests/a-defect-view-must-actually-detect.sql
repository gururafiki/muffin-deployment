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

rollback;
