-- A FUNNEL ASSERTS THAT EACH STAGE GATES THE NEXT. THIS ONE HAS TO EARN IT.
--
-- The coverage dashboard draws a funnel over universe -> symbol -> profile -> sector -> industry,
-- because those genuinely are nested: sector and industry are read off the `equity/profile`
-- response, and that response needs a symbol to ask for. Every other facet is drawn as bars.
--
-- WHY THE SPLIT EXISTS. Measured 2026-08-28, `metrics` (8,948) EXCEEDS `statements` (8,842) —
-- metrics also come straight from SEC XBRL rather than only from stored statements. Putting the
-- full set in one funnel would have asserted a pipeline that does not exist, and the picture would
-- have looked perfectly plausible.
--
-- So this test guards the claim rather than the drawing: if the chain ever stops being nested, the
-- funnel is lying and must be demoted to bars. It is the kind of thing that only breaks when
-- someone adds a second source for a stage — exactly what happened to metrics.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZF','Funnelia','ZF',false)
  on conflict (iso2) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;

-- FIXTURES, BECAUSE BOTH ASSERTIONS PASS VACUOUSLY ON AN EMPTY DATABASE. The first version of this
-- test reported `the cross accounts for every security (<NULL> = <NULL>)` and was green — which is
-- the "a measurement that does not consume its own result measures nothing" failure, in a guard.
--
-- Three securities on purpose: one fully classified, one with a symbol but NO SECTOR (the case the
-- 'unknown' bucketing exists for), and one with nothing at all.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-00000000f001','Funnel Full','equity','ZF'),
  ('00000000-0000-0000-0000-00000000f002','Funnel No Sector','equity','ZF'),
  ('00000000-0000-0000-0000-00000000f003','Funnel Bare','equity','ZF')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id) values
  ('ticker','ZFFULL','00000000-0000-0000-0000-00000000f001'),
  ('ticker','ZFNOSEC','00000000-0000-0000-0000-00000000f002')
on conflict (kind_code, value) do nothing;

-- `coverage_current` reads the MATERIALIZED `security_facets`, so rows inserted in this
-- transaction are invisible until it is rebuilt. NON-concurrently, deliberately: `refresh ...
-- concurrently` cannot run inside a transaction block, and a test that cannot roll back is not a
-- test.
refresh materialized view market.security_facets;

do $$
declare r record; bad text := '';
begin
  for r in
    select security_type_code,
           sum(securities)     as universe,
           sum(with_symbol)    as sym,
           sum(with_profile)   as prof,
           sum(with_sector)    as sect,
           sum(with_industry)  as ind
      from market.coverage_current
     where dimension = 'security_type'
     group by security_type_code
  loop
    -- Each stage must be <= the one above it. Equality is fine; exceeding it is not.
    if r.sym  > r.universe then bad := bad || format('%s: symbol %s > universe %s. ', r.security_type_code, r.sym, r.universe); end if;
    if r.prof > r.sym      then bad := bad || format('%s: profile %s > symbol %s. ', r.security_type_code, r.prof, r.sym); end if;
    if r.sect > r.prof     then bad := bad || format('%s: sector %s > profile %s. ', r.security_type_code, r.sect, r.prof); end if;
    if r.ind  > r.sect     then bad := bad || format('%s: industry %s > sector %s. ', r.security_type_code, r.ind, r.sect); end if;
  end loop;

  if bad <> '' then
    raise exception
      'THE FUNNEL IS NOT NESTED: %  A stage exceeding the one above it means the dashboard is '
      'asserting a dependency that does not hold — the same way `metrics` exceeds `statements` '
      'because metrics also come from XBRL. Either the chain changed, or a stage gained a second '
      'source; in both cases the funnel must be demoted to bars rather than left to mislead.', bad;
  end if;
  raise notice '  ok  universe >= symbol >= profile >= sector >= industry, for every security type';
end $$;

-- ── AND THE CROSS MUST ACCOUNT FOR EVERY SECURITY ─────────────────────────────────────────────
--
-- A null country or a null sector is a REAL population — "securities with no sector" is precisely
-- the gap this view exists to show — so the cross buckets them as 'unknown' rather than dropping
-- them. If the cross ever totalled less than the universe, the dashboard would under-report the
-- gap while looking complete, which is the worst direction for this particular metric to fail in.
do $$
declare cross_total bigint; type_total bigint;
begin
  select sum(securities) into cross_total
    from market.coverage_current where dimension = 'country_sector';
  select sum(securities) into type_total
    from market.coverage_current where dimension = 'security_type';

  if coalesce(type_total,0) = 0 then
    raise exception
      'the fixtures produced NO securities in coverage_current — this assertion would pass '
      'vacuously (<NULL> = <NULL>), which is how it shipped the first time. Check that '
      'security_facets was refreshed after the inserts.';
  end if;

  if coalesce(cross_total,0) <> coalesce(type_total,0) then
    raise exception
      'the country x sector cross totals % against the universe % — a null country or sector is '
      'being DROPPED rather than bucketed as unknown, so the dashboard under-reports the gap while '
      'appearing complete', cross_total, type_total;
  end if;
  raise notice '  ok  the cross accounts for every security (% = %)', cross_total, type_total;
end $$;

rollback;
