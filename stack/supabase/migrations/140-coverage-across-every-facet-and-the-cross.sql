-- COVERAGE YOU CAN NAVIGATE: WHOLE UNIVERSE -> COUNTRY -> SECTOR -> THE CROSS.
--
-- `coverage_current` tracked nine facets. The question it could not answer was "do we have
-- statements, price history, news, leadership, insider activity, filings and dividends for THIS
-- country and THIS sector" — because two thirds of the facets were absent and the cross did not
-- exist as a dimension. Both are added here.
--
-- Measured 2026-08-28, all present as data and none of it tracked:
--
--   share stats 11,533 · price history (weekly) 10,050 · analyst estimates 8,989 · news 5,446
--   filings 3,218 · dividends 1,944 · leadership 710 · quarterly statements 602
--   insider activity 537 · deep daily history 52
--
-- ── THE ONE THAT COULD NOT BE A JOIN, AND WHY IT MATTERS TWICE ────────────────────────────────
--
-- Nine of the ten are cheap. `price history` is not: `select distinct security_id from
-- security_price where grain = 'weekly'` measured **7.9 s**, and rewriting it as a per-security
-- EXISTS made it WORSE (8.7 s). The plan is already optimal — an index-only scan on
-- `security_price_grain_date_idx` — and the cost is `read=14,489` buffer misses, because that
-- index is 853 MB and does not stay in cache on this node.
--
-- WARM IT IS 329 ms AND COLD IT IS 4.9-8.7 s. `sample_coverage()` runs twice a day, which is
-- exactly often enough to be cold every time, and the PostgREST role's statement timeout is EIGHT
-- SECONDS — so this would have been a coin flip on every run. `sample_coverage` even carries a
-- `set_config('statement_timeout','30s')`, which does nothing: PostgreSQL arms the timer once at
-- statement start, and an RPC is one statement. That is the same trap that made `sample_universe`
-- time out in production after being justified at 771 ms — on a warm cache.
--
-- So the flag becomes a COLUMN, exactly like `daily_history_from` (measured: 8 ms). And the same
-- change fixes a second thing nobody had measured: **`pending_price_history` costs 5.8 s today**,
-- because it asks the identical question with the identical left join. The resource's own backlog
-- read was already two seconds from the limit.

-- ── THE MARKER ────────────────────────────────────────────────────────────────────────────────
alter table market.security add column if not exists price_history_from date;
comment on column market.security.price_history_from is
  'Earliest WEEKLY bar held for this security. A stored marker rather than a scan: asking security_price directly costs 7.9s cold, against 8ms here. Written by security-price-history; backfilled once by migration 140.';

-- ONE-SHOT, because a migration re-runs on every deploy and this aggregate is 7.2 s. Schema
-- statements are idempotent by construction; a backfill is not. It is safe to run here and
-- nowhere else: migrations apply as superuser through psql, with no PostgREST timeout.
do $$
declare n bigint;
begin
  if exists (select 1 from market.one_shot where key = '140-backfill-price-history-from') then
    raise notice '  --  140: price_history_from already backfilled, skipping';
  else
    with first_bar as (
      select security_id, min(date) as first_date
        from market.security_price where grain = 'weekly' group by security_id
    )
    update market.security s
       set price_history_from = f.first_date
      from first_bar f
     where f.security_id = s.security_id and s.price_history_from is distinct from f.first_date;
    get diagnostics n = row_count;
    raise notice '  --  140: backfilled price_history_from for % securities', n;
    insert into market.one_shot (key, reason) values
      ('140-backfill-price-history-from',
       'A scan of security_price for weekly history costs 7.9s cold against 8ms for a column, and sample_coverage is bounded by the 8s PostgREST statement timeout.');
  end if;
end $$;

-- ── AND THE BACKLOG THAT ASKED THE SAME EXPENSIVE QUESTION ────────────────────────────────────
--
-- `pending_price_history` left-joined `security_price ... grain = 'weekly'` to find securities with
-- none. Measured at 5.8 s, which is a resource's backlog read two seconds from the role's timeout —
-- and it would only get slower as the weekly series grows. The marker answers it directly.
drop view if exists market.pending_price_history;
create view market.pending_price_history as
select
  s.security_id,
  sym.symbol,
  coalesce(ps.symbol, sym.symbol) as fetch_symbol,
  coalesce(max(h.weight), 0)      as best_weight
from market.security s
join market.security_symbol sym on sym.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and s.price_history_from is null
  and (s.price_history_missing_at is null
       or s.price_history_missing_at < now() - interval '30 days')
group by s.security_id, sym.symbol, coalesce(ps.symbol, sym.symbol)
order by best_weight desc, s.security_id;

comment on view market.pending_price_history is
  'Equities with no weekly history yet, heaviest fund holding first. Keyed on the price_history_from MARKER rather than a scan of security_price: the left-join form measured 5.8s, two seconds from the PostgREST role timeout, and grew with the series.';

grant select on market.pending_price_history to service_role;

notify pgrst, 'reload schema';

-- ── THE VIEW ──────────────────────────────────────────────────────────────────────────────────
--
-- DROP FIRST: `create or replace view` can only APPEND columns, and this both adds ten and changes
-- nothing else — but `completeness` below is rebuilt too, and the two must be replaced together.
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
    (qt.security_id  is not null) as has_quarters
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
  count(*) filter (where d.has_quarters)                 as with_quarters
from dims d
join completeness c using (security_id)
group by d.dimension, coalesce(d.bucket, 'unknown'), d.security_type_code;

comment on view market.coverage_current is
  'Completeness across nineteen facets and eleven dimensions, including the country x sector cross. Read the SAMPLE, never this view: it is ~1s and the dashboards refresh every 30s.';

grant select on market.coverage_current to service_role, anon, authenticated;

-- ── THE SNAPSHOT GAINS THE SAME COLUMNS ───────────────────────────────────────────────────────
alter table market.coverage_sample add column if not exists with_price_history bigint;
alter table market.coverage_sample add column if not exists with_daily_history bigint;
alter table market.coverage_sample add column if not exists with_news         bigint;
alter table market.coverage_sample add column if not exists with_leadership   bigint;
alter table market.coverage_sample add column if not exists with_insider      bigint;
alter table market.coverage_sample add column if not exists with_filings      bigint;
alter table market.coverage_sample add column if not exists with_dividends    bigint;
alter table market.coverage_sample add column if not exists with_share_stats  bigint;
alter table market.coverage_sample add column if not exists with_estimates    bigint;
alter table market.coverage_sample add column if not exists with_quarters     bigint;

-- ── AND THE SAMPLER WRITES THEM ───────────────────────────────────────────────────────────────
--
-- `select *` is deliberately NOT used: the column order of a view is not a contract, and an insert
-- positional on it would silently mis-file every facet the day someone reorders the select. Named
-- both sides.
--
-- The `set_config('statement_timeout', ...)` the previous version carried is REMOVED rather than
-- raised. PostgreSQL arms the statement timer ONCE, at statement start, and a PostgREST RPC is a
-- single statement — so it never did anything, and leaving it in implies a protection that does
-- not exist. The real defence is that the expensive facet is now a column: measured, the whole
-- view is ~1s against the role's 8s ceiling.
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
  insert into market.coverage_sample (
    sampled_at, dimension, bucket, security_type_code, securities, complete,
    with_symbol, with_sector, with_industry, with_price, with_performance,
    with_profile, with_fundamentals, with_statements, with_metrics,
    priced_3d, priced_7d, priced_30d,
    with_price_history, with_daily_history, with_news, with_leadership, with_insider,
    with_filings, with_dividends, with_share_stats, with_estimates, with_quarters)
  select ts, dimension, bucket, security_type_code, securities, complete,
         with_symbol, with_sector, with_industry, with_price, with_performance,
         with_profile, with_fundamentals, with_statements, with_metrics,
         priced_3d, priced_7d, priced_30d,
         with_price_history, with_daily_history, with_news, with_leadership, with_insider,
         with_filings, with_dividends, with_share_stats, with_estimates, with_quarters
    from market.coverage_current
  on conflict (sampled_at, dimension, bucket, security_type_code) do nothing;

  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function market.sample_coverage() from public;
grant execute on function market.sample_coverage() to service_role;

notify pgrst, 'reload schema';
