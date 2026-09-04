-- THE PRESENCE RULES EXIST TWICE, SO DRIFT MUST BE DETECTABLE RATHER THAN MERELY DEPRECATED.
--
-- `coverage_current` answers completeness for the whole universe; `security_facet_status` answers
-- it for one security. They cannot share SQL: `coverage_current`'s `base` CTE is declared
-- `as materialized` because it is referenced once per dimension and PostgreSQL 12+ would otherwise
-- inline and re-run it ten times — and that hint is exactly what stops a single-security filter
-- being pushed through it.
--
-- Same-fact-in-two-places is a trap this schema has paid for repeatedly (the venue map drifted to
-- 54 rows against 38, so `security-local-symbols` resolved symbols on sixteen venues
-- `exchange-listings` never swept). The mitigation that works is the one migration 137 used for
-- suffix->venue: keep both and ASSERT they agree.
--
-- The fixture makes the two disagree if either drifts: one equity holding a handful of facets and
-- missing the rest, and one BOND, whose whole point is that most facets are not required of it —
-- a flat definition reports 55% of the universe permanently broken, which is the calibration
-- `required_facet` exists to prevent.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values
  ('equity','Equity'), ('bond','Bond') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZQ','Facetia','ZQ',false)
  on conflict (iso2) do nothing;
insert into market.currency (code) values ('USD') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, sic) values
  ('00000000-0000-0000-0000-000000017001','T170 Equity','equity','ZQ','7372'),
  ('00000000-0000-0000-0000-000000017002','T170 Bond',  'bond',  'ZQ',null)
on conflict (security_id) do nothing;

-- A couple of facets present, so neither "all" nor "none" could pass by accident.
-- `source_code` is NOT NULL and a foreign key; `data_source` rows are seeded by migrations 10, 13
-- and 67 rather than learned at runtime, so 'yfinance' exists by the time this runs.
insert into market.security_profile (security_id, source_code) values
  ('00000000-0000-0000-0000-000000017001', 'yfinance') on conflict do nothing;
-- `security_price` is (security_id, date, close, grain) — it carries no source.
insert into market.security_price (security_id, date, close) values
  ('00000000-0000-0000-0000-000000017001', current_date - 1, 10)
on conflict do nothing;

-- `security_facets` is MATERIALIZED: rows inserted in this transaction are invisible until the
-- spine is rebuilt. Non-concurrently, because `refresh ... concurrently` cannot run inside a
-- transaction block and a test that cannot roll back is not a test.
refresh materialized view market.security_facets;

do $$
declare
  eq constant uuid := '00000000-0000-0000-0000-000000017001';
  bd constant uuid := '00000000-0000-0000-0000-000000017002';
  n_facets int; n_present int; n_applicable int; n_required int;
  bond_required int; bond_facets int;
  cov_present bigint; cov_applicable bigint;
  own_present bigint; own_applicable bigint;
begin
  -- 1. EVERY FACET IS REPORTED FOR EVERY SECURITY, present or not. A view that returned only what
  --    a security HAS could never answer "what is missing", which is the whole question.
  select count(*), count(*) filter (where present),
         count(*) filter (where applicable), count(*) filter (where required)
    into n_facets, n_present, n_applicable, n_required
    from market.security_facet_status where security_id = eq;
  if n_facets < 20 then
    raise exception 'every facet must be reported for a security: got % rows', n_facets;
  end if;
  if n_present = 0 or n_present = n_facets then
    raise exception 'the fixture must have SOME facets present and some absent: % of %',
      n_present, n_facets;
  end if;

  -- 2. THE ONES SEEDED ARE PRESENT, and one that was not is absent. Names the facets, so a
  --    renamed column cannot quietly report everything as missing.
  if not exists (select 1 from market.security_facet_status
                  where security_id = eq and facet = 'profile' and present) then
    raise exception 'a seeded profile must read as present';
  end if;
  if not exists (select 1 from market.security_facet_status
                  where security_id = eq and facet = 'price' and present) then
    raise exception 'a bar from yesterday must read as priced';
  end if;
  if exists (select 1 from market.security_facet_status
              where security_id = eq and facet = 'leadership' and present) then
    raise exception 'an unseeded facet must read as absent';
  end if;

  -- 3. `required` IS TYPED, and that is the calibration the whole number depends on. A bond
  --    arrives from an N-PORT filing and that is all it will ever be.
  select count(*) filter (where required), count(*)
    into bond_required, bond_facets
    from market.security_facet_status where security_id = bd;
  if bond_facets = 0 then
    raise exception 'a bond must still be reported, with fewer requirements';
  end if;
  if bond_required >= n_required then
    raise exception 'a bond must owe FEWER facets than an equity: bond %, equity %',
      bond_required, n_required;
  end if;

  -- 4. AND IT MUST AGREE WITH `coverage_current`, which is the point of the test. Compared over
  --    the security_type dimension so the two aggregations are the same population.
  select sum(c.present_facets), sum(c.applicable_facets)
    into cov_present, cov_applicable
    from market.coverage_current c
   where c.dimension = 'security_type';

  select count(*) filter (where present and applicable), count(*) filter (where applicable)
    into own_present, own_applicable
    from market.security_facet_status;

  if cov_present is distinct from own_present then
    raise exception 'present_facets disagree: coverage_current %, security_facet_status % — the two presence definitions have drifted',
      cov_present, own_present;
  end if;
  if cov_applicable is distinct from own_applicable then
    raise exception 'applicable_facets disagree: coverage_current %, security_facet_status % — the two applicability definitions have drifted',
      cov_applicable, own_applicable;
  end if;

  raise notice 'ok  completeness agrees with coverage (% facets, % present, % applicable)',
    n_facets, own_present, own_applicable;
end $$;

rollback;
