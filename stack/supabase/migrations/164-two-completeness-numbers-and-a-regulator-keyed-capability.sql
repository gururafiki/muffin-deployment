-- Two completeness numbers, and a capability keyed on the regulator — IDEMPOTENT.
--
-- THREE THINGS, all found by reading a rendered dashboard rather than a diff.
--
-- 1. `complete %` reads as "we have everything about this" and means "holds the nine facets in
--    `required_facet`". A country can read **100%** while not one of its companies has a business
--    line. The gate is right and the LABEL was wrong, so the number keeps its meaning and becomes
--    `core %`, and a second number — `present_facets / applicable_facets` — answers breadth.
--
-- 2. `sec_filers` answered "has a CIK". Migration 163 replaced that with a resolved capability, so
--    the dimension becomes `segment_source` with THREE buckets: the regulator that can serve it,
--    `resolvable` (its jurisdiction has an enabled source, id unresolved) or `none`. The middle one
--    is the addressable backlog, and nothing could previously see it — a Korean company and a
--    Cayman shell were the same "no".
--
-- 3. Renaming now is nearly free. `sec_filers` has days of sample history; after DART ships it
--    would have months, under a name that had stopped being true.
--
-- COST, because `sample_coverage` is ONE PostgREST statement under the role's 8-SECOND timeout and
-- migration 140 exists because a single added facet took this view to 7.9 s. `security_disclosure`
-- is two lateral lookups per security over small control tables; the four facet joins were already
-- measured (+20% with `segments` read off the bounded spine rather than the fact table, which
-- grows with filing depth). Re-timed against a production-shaped fixture before shipping.

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
    -- THE CAPABILITY, RESOLVED BY REGULATOR RATHER THAN BY CIK. `f2.cik is not null` answered
    -- "does this file with SEC", which is the same question as "can this have segments" only while
    -- SEC is the only source. `security_disclosure` (migration 163) answers the real one, in three
    -- states, so Korea becomes a control-table row rather than a redefinition of this view.
    (sd.capability = 'held')                          as segment_capable,
    (sd.capability = 'resolvable')                    as segment_resolvable,
    coalesce(sd.segment_source, 'none')               as segment_source,
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
  left join market.security_disclosure sd using (security_id)
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
all_facets as (
  select security_id, 'symbol' as facet, has_symbol as present, true as applicable from base
  union all select security_id, 'sector', has_sector, true from base
  union all select security_id, 'industry', has_industry, true from base
  union all select security_id, 'price', has_price, true from base
  union all select security_id, 'performance', has_performance, true from base
  union all select security_id, 'profile', has_profile, true from base
  union all select security_id, 'fundamentals', has_fundamentals, true from base
  union all select security_id, 'statements', has_statements, true from base
  union all select security_id, 'metrics', has_metrics, true from base
  union all select security_id, 'price_history', has_price_history, true from base
  union all select security_id, 'daily_history', has_daily_history, true from base
  union all select security_id, 'news', has_news, true from base
  union all select security_id, 'leadership', has_leadership, true from base
  union all select security_id, 'insider', has_insider, true from base
  union all select security_id, 'filings', has_filings, true from base
  union all select security_id, 'dividends', has_dividends, true from base
  union all select security_id, 'share_stats', has_share_stats, true from base
  union all select security_id, 'estimates', has_estimates, true from base
  union all select security_id, 'quarters', has_quarters, true from base
  union all select security_id, 'sic', has_sic, segment_capable from base
  union all select security_id, 'segments', has_segments, segment_capable from base
  union all select security_id, 'segment_geography', has_segment_geography, segment_capable from base
  union all select security_id, 'weighted_industry', has_weighted_industry, segment_capable from base
),
richness as (
  -- HOW MUCH OF WHAT A SECURITY COULD HAVE, IT HAS — the second completeness number, and a
  -- different question from `complete`.
  --
  -- `complete` is a GATE: does this hold every facet `required_facet` demands of its type. It is
  -- typed on purpose, and it stays exactly as it was — but it was labelled "complete %", which
  -- reads as "we have everything about this company" when it means "has the nine". A country can
  -- read 100% while not one of its companies has a business line.
  --
  -- This is BREADTH: 23 facets, of which the four regulator-sourced ones are applicable only when
  -- some regulator can actually serve the security. Charging a Cayman shell for a segment it can
  -- never have is the ETF/`price` miscalibration that made 74 funds read 0% complete, and a
  -- structurally unreachable number gets ignored within a week.
  --
  -- ONE RULE, APPLIED TO EVERY TYPE. A bond will read low here and that is TRUE — this pipeline
  -- knows a maturity and a coupon about it and little else. `complete` is the number that respects
  -- typing; this one is the number that respects capability.
  select
    security_id,
    count(*) filter (where present and applicable) as present_facets,
    count(*) filter (where applicable)             as applicable_facets
  from all_facets
  group by security_id
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
  -- ── WHICH REGULATOR CAN SERVE THIS SECURITY ───────────────────────────────────────────────
  -- Was `sec_filer` with yes/no. Segment disclosure comes from a REGULATOR, not from the United
  -- States: Korea's DART is measured viable through the same parser, so a yes/no on the CIK would
  -- start reporting the wrong thing the day it ships. Three buckets, and the middle one is the
  -- addressable backlog nothing could previously see.
  union all select 'segment_source',
    case b.segment_source when 'none' then
      case when b.segment_resolvable then 'resolvable' else 'none' end
    else b.segment_source end,
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
  -- THE DENOMINATOR FOR THE FOUR SEC-ONLY FACETS, in every dimension rather than only in the
  -- `sec_filer` one. Without it a panel can show `with_segments` but has nothing honest to divide
  -- it by: `with_segments / securities` for a country is a number about how many of its companies
  -- file with SEC, not about coverage, and it reads as a gap. Free — `is_sec_filer` is already in
  -- `base`, off a column on a table `base` already joins.
  count(*) filter (where d.segment_capable)              as segment_capable,
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
  count(*) filter (where d.has_weighted_industry)        as with_weighted_industry,
  -- ── TWO COMPLETENESS NUMBERS, BECAUSE ONE WAS AMBIGUOUS ──────────────────────────────────
  -- `complete` counts securities holding every REQUIRED facet, and stays exactly as it was — the
  -- 9 rows in `required_facet` for an equity. It is now labelled `core %` on every panel, because
  -- "complete" was read as "we have everything about this" and a country can hold all nine while
  -- having no business lines at all.
  --
  -- `present_facets / applicable_facets` is the second number: how much of what a security COULD
  -- have it actually has. Applicable EXCLUDES the four regulator-sourced facets for a security no
  -- regulator can serve, so it never charges a Cayman shell for a segment it can never have —
  -- which is the ETF/`price` miscalibration that made 74 funds read 0% complete.
  sum(r.present_facets)                                  as present_facets,
  sum(r.applicable_facets)                               as applicable_facets
from dims d
join completeness c using (security_id)
join richness r using (security_id)
group by d.dimension, coalesce(d.bucket, 'unknown'), d.security_type_code;

comment on view market.coverage_current is
  'Completeness across 23 facets and 12 dimensions. TWO numbers, deliberately: `complete` is a typed GATE (holds every facet required_facet demands of its type) and `present_facets/applicable_facets` is BREADTH (how much of what it could have, it has — with the four regulator-sourced facets applicable only where some regulator can serve it). The `segment_source` dimension names WHICH regulator, or `resolvable` / `none`.';

-- ── The snapshot follows the shape ────────────────────────────────────────────────────────────
alter table market.coverage_sample add column if not exists segment_capable    integer;
alter table market.coverage_sample add column if not exists present_facets     integer;
alter table market.coverage_sample add column if not exists applicable_facets  integer;
-- `sec_filers` is left in place rather than dropped: it holds real history under the old name, and
-- a column dropped from a sample table takes its past with it. It simply stops being written.
comment on column market.coverage_sample.sec_filers is
  'SUPERSEDED by segment_capable (migration 164) and no longer written. Retained because it holds real history: dropping a sample column deletes the past rather than renaming it.';

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
    sampled_at, dimension, bucket, security_type_code, securities, segment_capable, complete,
    present_facets, applicable_facets,
    with_symbol, with_sector, with_industry, with_price, with_performance,
    with_profile, with_fundamentals, with_statements, with_metrics,
    priced_3d, priced_7d, priced_30d,
    with_price_history, with_daily_history, with_news, with_leadership, with_insider,
    with_filings, with_dividends, with_share_stats, with_estimates, with_quarters,
    with_sic, with_segments, with_segment_geography, with_weighted_industry)
  select ts, dimension, bucket, security_type_code, securities, segment_capable, complete,
         present_facets, applicable_facets,
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
