-- Track the segment family in coverage, against the population that can HAVE it — IDEMPOTENT.
--
-- `coverage_current` measures 24 facets and knew nothing about the business-line work: segments,
-- the geography breakdown, SEC's own SIC code, or the weighted classification that is the whole
-- point of the segment table ("Amazon is 62% consumer-discretionary by revenue and 57%
-- information-technology BY PROFIT").
--
-- THE HARD PART IS THE DENOMINATOR, NOT THE COLUMN. Segment disclosure comes from SEC filings and
-- nowhere else — measured 2026-08-29, ESEF block-tags its IFRS 8 notes as text and EDINET carries
-- zero segment axes — so 8,834 of 12,350 equities can NEVER have one. Adding `segments` to
-- `required_facet` would report ~71% of the universe permanently broken, which is precisely the
-- miscalibration that made ETFs read 0% complete (they were required to have `price`, which this
-- pipeline has never produced for an ETF). A completeness number that is structurally unreachable
-- gets ignored within a week, and then the real regressions go with it.
--
-- So this adds a `sec_filer` DIMENSION instead. Filter to `yes` and segment coverage is measured
-- against the population that can have it; the facet columns are reported everywhere but gate
-- nothing.
--
-- COST, because there is an 8-SECOND CEILING AND IT IS ALREADY TIGHT. Migration 140 exists
-- because one added facet took this view to 7.9 s and `sample_coverage` is an RPC — one statement
-- under the PostgREST role's timeout, with the `set_config('statement_timeout','30s')` inside it
-- doing nothing. So an addition here is a real risk rather than a free column.
--
-- Measured on a production-shaped database (27,600 securities, 3,500 of them SEC filers, 612,000
-- segment facts), the same definition with and without these additions:
--
--     migration 140 definition        172, 172, 177 ms
--     + 5 facets + 1 dimension        242, 245, 257 ms      (+42%)
--     …with `segments` off the SPINE  202, 206, 214 ms      (+20%)
--
-- THE DIFFERENCE BETWEEN THOSE LAST TWO IS MIGRATION 140'S OWN LESSON APPLIED AGAIN. Reading
-- `select distinct security_id from security_segment` costs 56 ms at 612,000 facts and GROWS WITH
-- HISTORY DEPTH — every filing parsed adds ~180 rows per company, and the backlog is 33,000
-- filings deep — while the answer it computes does not change. Off the spine (one row per
-- security/axis/member: 10,200 rows against 612,000) it is **5.8 ms** and bounded by companies x
-- members rather than periods x metrics. Exactly why `price_history_from` is a column and not a
-- 7.9 s scan of `security_price`.
--
-- Two of the five facets are free: `sic` and `cik` are COLUMNS on `market.security`, which `base`
-- already joins for `price_history_from`. The residual +20% is the twelfth dimension, which is one
-- more pass over a materialized 27,600-row CTE — proportional to the universe, not to segments.

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
    (mt.security_id  is not null) as has_metrics,
    -- ── THE TEN ADDED HERE ────────────────────────────────────────────────────────────────────
    -- Nine are cheap EXISTS-style joins (measured 9-74 ms each). `price history` is a COLUMN, not
    -- a join: the scan form costs 7.9 s cold and `sample_coverage` has an 8 s ceiling.
    (f2.price_history_from is not null) as has_price_history,
    (f2.daily_history_from is not null) as has_daily_history,
    (nw.security_id  is not null) as has_news,
    (of.security_id  is not null) as has_leadership,
    (it.security_id  is not null) as has_insider,
    (fl.security_id  is not null) as has_filings,
    (dv.security_id  is not null) as has_dividends,
    (ss.security_id  is not null) as has_share_stats,
    (es.security_id  is not null) as has_estimates,
    (qt.security_id  is not null) as has_quarters,
    -- ── THE SEGMENT FAMILY (2026-08-29) ───────────────────────────────────────────────────────
    -- `sic` and `cik` are COLUMNS on a table already joined for `price_history_from`, so they are
    -- free. The other three are joins and were measured before being added; see the header.
    (f2.sic          is not null) as has_sic,
    (f2.cik          is not null) as is_sec_filer,
    (sg.security_id  is not null) as has_segments,
    (gg.security_id  is not null) as has_segment_geography,
    (wi.security_id  is not null) as has_weighted_industry
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
  -- THE MARKERS, read straight off `security`. `security_facets` does not carry them, so the
  -- table is joined once for both.
  left join market.security f2 using (security_id)
  left join (select distinct security_id from market.news_security)          nw using (security_id)
  left join (select distinct security_id from market.security_officer)       of using (security_id)
  left join (select distinct security_id from market.insider_trade)          it using (security_id)
  left join (select distinct security_id from market.security_filing)        fl using (security_id)
  left join (select distinct security_id from market.security_corporate_action
              where kind = 'dividend')                                       dv using (security_id)
  left join (select distinct security_id from market.security_share_stats)   ss using (security_id)
  left join (select distinct security_id from market.security_estimate)      es using (security_id)
  left join (select distinct security_id from market.security_statement
              where period_type = 'quarter')                                 qt using (security_id)
  left join (select distinct security_id from market.security_profile)      pr using (security_id)
  -- Business lines — FROM THE SPINE, NOT THE FACT TABLE, and that is migration 140's own lesson
  -- applied again. `select distinct security_id from security_segment` measured **56 ms** at
  -- 612,000 facts and grows with HISTORY DEPTH: every filing adds ~180 rows per company, so the
  -- table is heading for millions while the answer to "does this company have a business-line
  -- breakdown" does not change. The spine is one row per (security, axis, member) — **10,200
  -- against 612,000 here, 60x smaller** — and is bounded by companies x members rather than by
  -- periods x metrics. Measured at **1.4 ms**.
  --
  -- It also defines the facet better: the spine is partition-1 annual rows, so this counts
  -- companies with a READABLE breakdown rather than ones that merely have a row somewhere.
  left join (select distinct security_id from market.security_segment_spine) sg using (security_id)
  -- WHERE it earns. The SPINE here rather than the base table, because a geography row is only
  -- readable once the member has a published meaning, and that is what the spine resolves. It is
  -- a matview at one row per (security, axis, member), so this is small.
  left join (select distinct security_id from market.security_segment_spine
              where kind = 'geography')                                     gg using (security_id)
  -- The weighted classification — "Amazon is 62% consumer-discretionary by revenue and 57%
  -- information-technology by profit". Distinct from `has_sector`, which only says a single label
  -- exists; this says the single label is known to be MISLEADING and by how much.
  left join (select distinct security_id from market.security_taxonomy
              where source_code in ('segment-revenue', 'segment-profit'))   wi using (security_id)
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
  -- ── THE POPULATION THAT CAN EVER HAVE SEGMENTS ────────────────────────────────────────────
  -- Segment disclosure comes from SEC filings and nothing else: measured 2026-08-29, ESEF
  -- block-tags its IFRS 8 notes as text and EDINET carries zero segment axes, so for a company
  -- with no CIK there is no source at all. 3,516 of 12,350 equities have one.
  --
  -- THIS IS A DIMENSION AND NOT A `required_facet` ROW, deliberately. Requiring `segments` of
  -- every equity would report ~71% of the universe permanently broken for something it can never
  -- have — the exact miscalibration that made ETFs read 0% complete because `price` was required
  -- of a type this pipeline has never produced bars for, and a number like that gets ignored
  -- within a week. As a dimension the same question is answerable and honest: filter to
  -- `sec_filer = yes` and segment coverage is measured against the population that can have it.
  union all select 'sec_filer',
    case when b.is_sec_filer then 'yes' else 'no' end,
    b.* from base b
  -- ── THE CROSS ─────────────────────────────────────────────────────────────────────────────
  -- 637 non-empty (country, sector, type) combinations, measured — small enough to sample twice a
  -- day and to render. A COMPOSITE TEXT bucket rather than a second column, because
  -- `coverage_sample`'s primary key is (sampled_at, dimension, bucket, security_type_code) and a
  -- nullable second key column cannot join a primary key. The separator is '|', and a null side
  -- becomes 'unknown' below rather than dropping the row — "securities with no sector" is exactly
  -- the gap this view exists to show.
  union all select 'country_sector',
    coalesce(b.country_iso2::text, 'unknown') || '|' || coalesce(b.sector_id::text, 'unknown'),
    b.* from base b
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
  count(*) filter (where d.has_price)                    as priced_30d,
  count(*) filter (where d.has_price_history)            as with_price_history,
  count(*) filter (where d.has_daily_history)            as with_daily_history,
  count(*) filter (where d.has_news)                     as with_news,
  count(*) filter (where d.has_leadership)               as with_leadership,
  count(*) filter (where d.has_insider)                  as with_insider,
  count(*) filter (where d.has_filings)                  as with_filings,
  count(*) filter (where d.has_dividends)                as with_dividends,
  count(*) filter (where d.has_share_stats)              as with_share_stats,
  count(*) filter (where d.has_estimates)                as with_estimates,
  count(*) filter (where d.has_quarters)                 as with_quarters,
  count(*) filter (where d.has_sic)                      as with_sic,
  count(*) filter (where d.has_segments)                 as with_segments,
  count(*) filter (where d.has_segment_geography)        as with_segment_geography,
  count(*) filter (where d.has_weighted_industry)        as with_weighted_industry
from dims d
join completeness c using (security_id)
group by d.dimension, coalesce(d.bucket, 'unknown'), d.security_type_code;

comment on view market.coverage_current is
  'Completeness across 28 facets and 12 dimensions, typed by market.required_facet. The `sec_filer` dimension exists because segment disclosure is SEC-only: filter to yes before reading segment coverage as a percentage, and note that `segments` is deliberately NOT a required facet, because 8,834 of 12,350 equities can never have one.';

-- ── The snapshot has to carry them, or the trend is of the old shape ─────────────────────────
alter table market.coverage_sample add column if not exists with_sic                integer;
alter table market.coverage_sample add column if not exists with_segments           integer;
alter table market.coverage_sample add column if not exists with_segment_geography  integer;
alter table market.coverage_sample add column if not exists with_weighted_industry  integer;

-- `create or replace function` PRESERVES THE EXISTING ACL, so drop-then-create.
drop function if exists market.sample_coverage();
create function market.sample_coverage()
returns integer
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  ts timestamptz := now();
  n  integer;
begin
  insert into market.coverage_sample (
    sampled_at, dimension, bucket, security_type_code, securities, complete,
    with_symbol, with_sector, with_industry, with_price, with_performance,
    with_profile, with_fundamentals, with_statements, with_metrics,
    priced_3d, priced_7d, priced_30d,
    with_price_history, with_daily_history, with_news, with_leadership, with_insider,
    with_filings, with_dividends, with_share_stats, with_estimates, with_quarters,
    with_sic, with_segments, with_segment_geography, with_weighted_industry)
  select ts, dimension, bucket, security_type_code, securities, complete,
         with_symbol, with_sector, with_industry, with_price, with_performance,
         with_profile, with_fundamentals, with_statements, with_metrics,
         priced_3d, priced_7d, priced_30d,
         with_price_history, with_daily_history, with_news, with_leadership, with_insider,
         with_filings, with_dividends, with_share_stats, with_estimates, with_quarters,
         with_sic, with_segments, with_segment_geography, with_weighted_industry
    from market.coverage_current
  on conflict (sampled_at, dimension, bucket, security_type_code) do nothing;

  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function market.sample_coverage() from public;
grant execute on function market.sample_coverage() to service_role;

grant select on market.coverage_current to anon, authenticated, service_role;

notify pgrst, 'reload schema';
