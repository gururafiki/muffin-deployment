-- COMPLETENESS IS TYPED, AND COVERAGE HAS DIMENSIONS.
--
-- `universe_sample` answers "how many rows are there". It cannot answer the question actually
-- worth asking: WHERE are the gaps. 148 scalars with no dimension on any of them cannot say which
-- countries are under-ingested, whether Tokyo is worse than New York, or which securities stopped
-- being priced.
--
-- ── WHY THIS IS CHEAP ─────────────────────────────────────────────────────────────────────────
--
-- `market.security_facets` is a MATERIALIZED view — 27,629 rows, 12 MB — already carrying every
-- dimension: country, sector, industry, cap band, style, currency, MSCI/FTSE tier and region,
-- income group. The whole aggregate below, every facet, grouped by country x type, measured
-- **392 ms** on the node.
--
-- ── WHY COMPLETENESS MUST BE TYPED ────────────────────────────────────────────────────────────
--
-- **15,159 of 27,629 securities are BONDS** and 12,350 are equities. A bond has no sector, no
-- P/E and no price series here — it arrives from an N-PORT filing and that is all it will ever
-- be. One flat definition of "fully ingested" would report 55% of the universe permanently
-- incomplete for facets that can never apply to it, and the number would be ignored within a week.
--
-- ── TWO TRAPS MEASURED WHILE BUILDING THIS ────────────────────────────────────────────────────
--
--   1. `performance` IS KEYED BY SYMBOL, NOT security_id — `scope = 'instrument'` with `scope_id`
--      holding `PMZ-U.TO`, not a uuid. The obvious join reported performance coverage as **0 of
--      27,629** and looked like a catastrophic ingestion failure; it is a join bug. The real
--      number is 11,589. (This schema records why: re-keying `performance.scope_id` needed a
--      hand-written migration, while anything keyed on `security_id` needed none.)
--   2. THE FIRST TIMING OF THIS QUERY WAS 15 ms AND WAS FICTION. The outer query selected only
--      `count(*)`, so PostgreSQL ELIMINATED every unused LEFT JOIN — they are on unique keys and
--      no column was referenced. Consuming every facet column gives the honest 392 ms. A
--      measurement that does not consume its own result measures nothing.

-- ── The control table ─────────────────────────────────────────────────────────────────────────
--
-- A row, not a migration — the same shape as `market.metric`, `market.macro_indicator` and
-- `tracked_fund`. Retyping what a security type owes is an edit in Studio, and the completeness
-- number moves with it.
--
-- ABSENCE MEANS NOT REQUIRED. A type with no rows here is always complete, which is the correct
-- reading for a bond (we ask nothing of it) and is why only the `true` rows are seeded: a table of
-- 81 mostly-false rows would be harder to read than the nine that carry meaning.
create table if not exists market.required_facet (
  security_type_code text    not null references market.security_type(code),
  facet              text    not null,
  required           boolean not null default true,
  primary key (security_type_code, facet)
);

insert into market.required_facet (security_type_code, facet) values
  -- An equity is the only thing this pipeline tries to know everything about.
  ('equity', 'symbol'), ('equity', 'sector'), ('equity', 'industry'), ('equity', 'price'),
  ('equity', 'performance'), ('equity', 'profile'), ('equity', 'fundamentals'),
  ('equity', 'statements'), ('equity', 'metrics'),
  -- An ETF has holdings, not accounts: no income statement, no P/E, no sector of its own.
  ('etf', 'symbol'), ('etf', 'price'), ('etf', 'performance')
on conflict (security_type_code, facet) do nothing;

-- ── The definition, as a VIEW ─────────────────────────────────────────────────────────────────
--
-- This is the SINGLE definition. `coverage_sample` below is literally a snapshot of it, so the
-- two can never disagree — this schema has already been bitten by one fact living in two places,
-- when the venue map drifted to 54 rows against 38 and silently stopped sweeping sixteen venues.
drop view if exists market.coverage_current;

create view market.coverage_current as
-- MATERIALIZED is load-bearing: `base` is referenced once per dimension below, and PostgreSQL 12+
-- INLINES a CTE by default. Inlined, this whole aggregate would be recomputed ten times.
with base as materialized (
  select
    f.security_id, f.security_type_code, f.symbol,
    f.country_iso2, f.sector_id, f.industry_code, f.cap_band, f.style,
    f.msci_tier, f.msci_region, f.income_group, f.currency_code,
    (f.symbol        is not null) as has_symbol,
    (f.sector_id     is not null) as has_sector,
    (f.industry_code is not null) as has_industry,
    (p30.security_id is not null) as has_price,
    (p7.security_id  is not null) as priced_7d,
    (p3.security_id  is not null) as priced_3d,
    (pf.symbol       is not null) as has_performance,
    (pr.security_id  is not null) as has_profile,
    (fu.security_id  is not null) as has_fundamentals,
    (st.security_id  is not null) as has_statements,
    (mt.security_id  is not null) as has_metrics
  from market.security_facets f
  -- "Priced" means a bar in the last 30 days, not a bar ever. A security whose newest close is
  -- two years old is not covered in any useful sense, and the window is what makes this an
  -- INDEX-ONLY scan of 215,730 entries (migration 130) instead of 10.9M rows.
  left join (select distinct security_id from market.security_price
              where date > current_date - 30) p30 using (security_id)
  left join (select distinct security_id from market.security_price
              where date > current_date - 7)  p7  using (security_id)
  left join (select distinct security_id from market.security_price
              where date > current_date - 3)  p3  using (security_id)
  -- ON SYMBOL. See trap 1 in the header: joining this on security_id silently reports 0%.
  left join (select distinct scope_id as symbol from market.performance
              where scope = 'instrument') pf on pf.symbol = f.symbol
  left join (select distinct security_id from market.security_profile)      pr using (security_id)
  left join (select distinct security_id from market.security_fundamentals) fu using (security_id)
  left join (select distinct security_id from market.security_statement)    st using (security_id)
  left join (select distinct security_id from market.security_metric)       mt using (security_id)
),
-- Facets unpivoted per security, so the CONTROL TABLE decides what counts. A hardcoded
-- expression here would make `required_facet` decorative.
facet_status as (
  select security_id, security_type_code, 'symbol'       as facet, has_symbol       as present from base
  union all select security_id, security_type_code, 'sector',      has_sector       from base
  union all select security_id, security_type_code, 'industry',    has_industry     from base
  union all select security_id, security_type_code, 'price',       has_price        from base
  union all select security_id, security_type_code, 'performance', has_performance  from base
  union all select security_id, security_type_code, 'profile',     has_profile      from base
  union all select security_id, security_type_code, 'fundamentals',has_fundamentals from base
  union all select security_id, security_type_code, 'statements',  has_statements   from base
  union all select security_id, security_type_code, 'metrics',     has_metrics      from base
),
completeness as (
  select fs.security_id,
         -- Present, OR not required of this type. A facet with no row in `required_facet` is not
         -- required, so a bond missing a sector is complete and an equity missing one is not.
         bool_and(fs.present or not coalesce(rf.required, false)) as complete
    from facet_status fs
    left join market.required_facet rf
           on rf.security_type_code = fs.security_type_code and rf.facet = fs.facet
   group by fs.security_id
),
-- Every dimension, unpivoted. `bucket` is text because these are labels, not keys.
dims as (
  select 'country'::text as dimension, b.country_iso2::text  as bucket, b.* from base b
  union all select 'sector',        b.sector_id::text,     b.* from base b
  union all select 'industry',      b.industry_code::text,  b.* from base b
  union all select 'cap_band',      b.cap_band::text,       b.* from base b
  union all select 'style',         b.style::text,          b.* from base b
  union all select 'msci_tier',     b.msci_tier::text,      b.* from base b
  union all select 'msci_region',   b.msci_region::text,    b.* from base b
  union all select 'income_group',  b.income_group::text,   b.* from base b
  union all select 'currency',      b.currency_code::text,  b.* from base b
  union all select 'security_type', b.security_type_code::text, b.* from base b
)
select
  d.dimension,
  -- A null dimension is a real population — "securities with no sector" is precisely the gap this
  -- view exists to show — so it is bucketed as 'unknown' rather than dropped by the group by.
  coalesce(d.bucket, 'unknown')                          as bucket,
  d.security_type_code,
  count(*)                                               as securities,
  count(*) filter (where c.complete)                     as complete,
  count(*) filter (where d.has_symbol)                   as with_symbol,
  count(*) filter (where d.has_sector)                   as with_sector,
  count(*) filter (where d.has_industry)                 as with_industry,
  count(*) filter (where d.has_price)                    as with_price,
  count(*) filter (where d.has_performance)              as with_performance,
  count(*) filter (where d.has_profile)                  as with_profile,
  count(*) filter (where d.has_fundamentals)             as with_fundamentals,
  count(*) filter (where d.has_statements)               as with_statements,
  count(*) filter (where d.has_metrics)                  as with_metrics,
  count(*) filter (where d.priced_3d)                    as priced_3d,
  count(*) filter (where d.priced_7d)                    as priced_7d,
  count(*) filter (where d.has_price)                    as priced_30d
from dims d
join completeness c using (security_id)
group by d.dimension, coalesce(d.bucket, 'unknown'), d.security_type_code;

-- ── The history ───────────────────────────────────────────────────────────────────────────────
--
-- The ONLY thing denormalized here is TIME, which is the whole point: history is the one thing a
-- view cannot give you, and "is coverage improving?" is the question being asked.
create table if not exists market.coverage_sample (
  sampled_at         timestamptz not null,
  dimension          text        not null,
  bucket             text        not null,
  security_type_code text        not null,
  securities         bigint,
  complete           bigint,
  with_symbol        bigint,
  with_sector        bigint,
  with_industry      bigint,
  with_performance   bigint,
  with_price         bigint,
  with_profile       bigint,
  with_fundamentals  bigint,
  with_statements    bigint,
  with_metrics       bigint,
  priced_3d          bigint,
  priced_7d          bigint,
  priced_30d         bigint,
  primary key (sampled_at, dimension, bucket, security_type_code)
);

create index if not exists coverage_sample_dim_idx
  on market.coverage_sample (dimension, bucket, sampled_at desc);

-- The sampler is a SNAPSHOT OF THE VIEW and nothing else. If a future change gives it its own
-- aggregate, the table and the view will disagree and the dashboard will quietly be wrong — which
-- is the failure mode the single-definition rule above exists to prevent.
create or replace function market.sample_coverage()
returns integer
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  ts timestamptz := now();
  n  integer;
begin
  perform set_config('statement_timeout', '30s', true);

  insert into market.coverage_sample (
    sampled_at, dimension, bucket, security_type_code, securities, complete,
    with_symbol, with_sector, with_industry, with_price, with_performance,
    with_profile, with_fundamentals, with_statements, with_metrics,
    priced_3d, priced_7d, priced_30d)
  select ts, dimension, bucket, security_type_code, securities, complete,
         with_symbol, with_sector, with_industry, with_price, with_performance,
         with_profile, with_fundamentals, with_statements, with_metrics,
         priced_3d, priced_7d, priced_30d
    from market.coverage_current
  on conflict (sampled_at, dimension, bucket, security_type_code) do nothing;

  get diagnostics n = row_count;
  return n;
end $$;

-- Retention, alongside the other observability tables.
create or replace function market.prune_observability(p_days integer default 400)
returns integer
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  cutoff timestamptz := now() - make_interval(days => p_days);
  n integer := 0; d integer;
begin
  delete from market.refresh_run     where started_at < cutoff;  get diagnostics d = row_count; n := n + d;
  delete from market.backlog_sample  where sampled_at < cutoff;  get diagnostics d = row_count; n := n + d;
  delete from market.universe_sample where sampled_at < cutoff;  get diagnostics d = row_count; n := n + d;
  delete from market.coverage_sample where sampled_at < cutoff;  get diagnostics d = row_count; n := n + d;
  return n;
end $$;

-- ── Grants and RLS ────────────────────────────────────────────────────────────────────────────
grant select, insert, update, delete on market.required_facet, market.coverage_sample to service_role;
grant select on market.coverage_current to service_role, anon, authenticated;
grant select on market.required_facet   to service_role, anon, authenticated;
grant select on market.coverage_sample  to metrics_ro;

alter table market.coverage_sample enable row level security;
alter table market.required_facet  enable row level security;

do $$ begin
  drop policy if exists coverage_sample_metrics_ro_read on market.coverage_sample;
  create policy coverage_sample_metrics_ro_read on market.coverage_sample
    for select to metrics_ro using (true);
  drop policy if exists required_facet_public_read on market.required_facet;
  -- Readable: it is the published definition of what "complete" means, not data about anyone.
  create policy required_facet_public_read on market.required_facet
    for select to anon, authenticated, metrics_ro using (true);
end $$;

revoke all on function market.sample_coverage() from public;
grant execute on function market.sample_coverage() to service_role;

notify pgrst, 'reload schema';
