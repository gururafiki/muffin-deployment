-- COMPLETENESS MUST BE MEASURED AGAINST THE POPULATION THAT CAN ACHIEVE IT.
--
-- WHY. `market.required_facet` exists because one flat definition of "complete" reported 55% of
-- the universe (15,159 bonds) permanently broken for facets a bond can never have. It was then
-- got wrong in the other direction: ETFs read **0% complete** because `price` was required of a
-- type this pipeline has never stored bars for, so the seed was the defect and not the data.
--
-- Segments are the same trap with a bigger blast radius. Segment disclosure comes from SEC
-- filings and nowhere else — measured 2026-08-29, ESEF block-tags its IFRS 8 notes as text and
-- EDINET carries zero segment axes — so **8,834 of 12,350 equities can never have one**. Adding
-- `segments` to `required_facet` for equity would drop headline completeness by ~71 points
-- overnight, against data that is not wrong. A completeness number that is structurally
-- unreachable gets ignored within a week, and the real regressions go with it.
--
-- THE FIXTURE MAKES THE TWO POPULATIONS DISAGREE: three securities, one an SEC filer with
-- segments and two without. A `sec_filer` dimension that did not split them would report the same
-- percentage for both, which is the number the panel exists to avoid.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZC','Coverland','ZC',false)
  on conflict (iso2) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000016001', 'T160 SEC Filer',   'equity', 'ZC', 1600001),
  ('00000000-0000-0000-0000-000000016002', 'T160 Foreign One', 'equity', 'ZC', null),
  ('00000000-0000-0000-0000-000000016003', 'T160 Foreign Two', 'equity', 'ZC', null)
on conflict (security_id) do nothing;

-- Only the SEC filer can have a business line, which is the whole point.
insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code) values
  ('00000000-0000-0000-0000-000000016001','srt:ProductOrServiceAxis','t:CloudMember','revenue','annual',date '2025-12-31',70,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000016001','srt:ProductOrServiceAxis','t:OtherMember','revenue','annual',date '2025-12-31',30,'USD',1,'sec-segments')
on conflict do nothing;

-- `security_facets` and `security_segment_spine` are MATERIALIZED, so nothing inserted in this
-- transaction is visible to coverage until both are rebuilt. Non-concurrently: `refresh ...
-- concurrently` cannot run inside a transaction block, and a test that cannot roll back is not one.
refresh materialized view market.security_facets;
refresh materialized view market.security_segment_spine;

do $$
declare
  required int;
  yes_pct numeric; no_pct numeric;
  yes_n int; no_n int;
  core_n int; present_n int; applicable_n int;
  -- DISTINCT names: reusing yes_n/no_n across assertions silently compared a bucket count against
  -- a security_type count, and the guard failed on arithmetic rather than on the rule.
  sec_secs int; none_secs int; sec_applicable int; none_applicable int; type_secs int;
begin
  -- 1. `segments` MUST NOT gate completeness, for any security type.
  select count(*) into required from market.required_facet where facet = 'segments';
  if required <> 0 then
    raise exception 'required_facet requires `segments` of % security type(s) — 8,834 of 12,350 equities have no CIK and no other source exists, so this reports the universe ~71%% broken against data that is correct', required;
  end if;
  -- Same for the other three, each of which is SEC-only or derived from it.
  select count(*) into required from market.required_facet
   where facet in ('sic', 'segment_geography', 'weighted_industry');
  if required <> 0 then
    raise exception '% SEC-only facet(s) are marked required — see above', required;
  end if;

  -- 2. The dimension must SPLIT the population, and NAME the regulator. It was `sec_filer` with
  --    yes/no; segment disclosure comes from a regulator rather than from the United States, so a
  --    boolean on the CIK stops being true the day DART ships.
  select securities, round(100.0 * with_segments / nullif(securities,0), 1)
    into yes_n, yes_pct
  from market.coverage_current
   where dimension = 'segment_source' and bucket = 'sec' and security_type_code = 'equity';
  select securities, round(100.0 * with_segments / nullif(securities,0), 1)
    into no_n, no_pct
  from market.coverage_current
   where dimension = 'segment_source' and bucket = 'none' and security_type_code = 'equity';

  if yes_n is null or no_n is null then
    raise exception 'the segment_source dimension does not produce both a `sec` and a `none` bucket (sec=%, none=%) — a denominator nobody can select is not a denominator', yes_n, no_n;
  end if;
  if yes_pct <= no_pct then
    raise exception 'securities SEC can serve report % percent segment coverage against % percent for those no regulator can — the split is inverted or absent', yes_pct, no_pct;
  end if;

  -- 3. TWO COMPLETENESS NUMBERS, AND THEY MUST MEAN DIFFERENT THINGS. `complete` is the typed GATE
  --    (holds every facet required_facet demands of its type). `present/applicable` is BREADTH.
  --    A view where they are equal has collapsed one into the other, and the whole reason for the
  --    second number is that a country could read 100 percent "complete" while not one of its
  --    companies had a business line.
  select complete, securities, present_facets, applicable_facets
    into core_n, type_secs, present_n, applicable_n
  from market.coverage_current
   where dimension = 'security_type' and bucket = 'equity' and security_type_code = 'equity';

  if applicable_n is null or applicable_n = 0 then
    raise exception 'applicable_facets is % for equities — breadth cannot be measured against nothing', coalesce(applicable_n::text,'null');
  end if;
  if present_n > applicable_n then
    raise exception 'present_facets (%) exceeds applicable_facets (%) — a security is being credited for a facet it cannot have', present_n, applicable_n;
  end if;

  -- 4. AND APPLICABLE MUST SHRINK FOR A SECURITY NO REGULATOR CAN SERVE. Four of the 23 facets are
  --    regulator-sourced; charging a Cayman shell for them is the ETF/`price` miscalibration, which
  --    made 74 funds read 0 percent complete against a facet this pipeline never produced for them.
  select securities, applicable_facets into none_secs, none_applicable
    from market.coverage_current
   where dimension = 'segment_source' and bucket = 'none' and security_type_code = 'equity';
  select securities, applicable_facets into sec_secs, sec_applicable
    from market.coverage_current
   where dimension = 'segment_source' and bucket = 'sec' and security_type_code = 'equity';
  if none_applicable::numeric / greatest(none_secs,1) >= sec_applicable::numeric / greatest(sec_secs,1) then
    raise exception 'a security no regulator can serve is charged for % facets each against % for one SEC can serve — the four regulator-sourced facets must not be applicable when nothing can supply them',
      round(none_applicable::numeric / greatest(none_secs,1), 1), round(sec_applicable::numeric / greatest(sec_secs,1), 1);
  end if;
end $$;

rollback;

\echo 'ok: segments never gate completeness, segment_source names the regulator, and breadth is measured against what a security can have'
