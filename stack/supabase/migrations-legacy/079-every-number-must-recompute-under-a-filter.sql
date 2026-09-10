-- EVERY NUMBER MUST RECOMPUTE WHEN A FILTER CHANGES, AND THE CLIENT CANNOT DO IT.
--
-- The app's returns come from `market.performance`, which is precomputed per instrument, per
-- country and per sector. Ask it "what did developed-market industrials do" and there is no row —
-- that bucket was never precomputed, and there are more buckets than anyone will precompute:
-- 6 classification lenses x sector x industry x cap band x style is a combinatorial space.
--
-- IT CANNOT BE DONE CLIENT-SIDE EITHER, and this is the part that would have shipped silently.
-- `PGRST_DB_MAX_ROWS` is 1000, so a client aggregating "all developed-market industrials" receives
-- the first 1,000 rows and averages them into a confident, wrong number with no error anywhere —
-- the exact failure this codebase has now hit three times (`market-verify`'s limit=5000 guard,
-- the `.limit(4000)` that returned 1,000, and the 2,704-row count I misread as 16 countries while
-- writing this migration). A weighted mean belongs where the rows are.
--
-- ── WHY NAMED ARRAY PARAMETERS AND NOT A `filters jsonb` ─────────────────────────────────────
--
-- The design sketch called for `aggregate_performance(filters jsonb, group_by text, period text)`.
-- Named parameters are strictly better here: PostgREST maps a JSON body onto them natively, each
-- one is typed, and `group_by` never reaches the planner as text to be interpolated. There is NO
-- dynamic SQL in this function — the bucket is a `case` over a fixed whitelist, so an unknown
-- `p_group_by` returns nothing rather than executing anything, and the query plan is stable.
--
-- Every filter is `(p_x is null or col = any(p_x))`: null means "no opinion", an empty array means
-- "match nothing". Those are different questions and the distinction is load-bearing — a UI that
-- clears its last chip must not silently switch from "no rows" to "the whole world".
--
-- ── WEIGHTING ────────────────────────────────────────────────────────────────────────────────
--
-- By `market_cap_usd`, NOT `fund_holding.weight`. Fund weights exist only for names a tracked ETF
-- happens to hold, are up to a quarter stale (N-PORT is quarterly), and do not sum to 100 — EWT's
-- own filing sums to 110.38. Market cap is the only comparable figure across 27,629 securities, and
-- it is already denominated in USD by `security_market_cap_usd`.
--
-- Both means are returned. `change_pct` is cap-weighted; `change_pct_equal` is the plain mean. They
-- answer different questions — one mega-cap can carry a cap-weighted sector while the median name
-- in it fell — and returning both makes that visible instead of a choice buried in this file.
--
-- ── WHAT MUST ALWAYS COME BACK WITH THE NUMBER ───────────────────────────────────────────────
--
-- `constituents`, `bucket_securities` and `weight_covered`. A bucket of three names must not render
-- like a bucket of three hundred, and a number computed over 12% of a sector by value is not that
-- sector's return. `weight_covered` is the share of the bucket's market cap that actually had a
-- return — the denominator includes securities with NO performance row, which is the only way the
-- ratio can ever fall below 1 and therefore the only way it can warn anyone.
--
-- NULL `total_return_pct` is dropped from its mean rather than coalesced to `change_pct`, and
-- `total_return_constituents` says how many contributed. Migration 72 is emphatic that NULL there
-- means "not computed", not "paid no income".

-- DROP-THEN-CREATE, NOT `create or replace`. `create or replace function` PRESERVES THE EXISTING
-- ACL, so on a redeploy the grant statements at the foot of this file can only ever ADD privileges
-- — a future line tightening them would apply cleanly, report success, and change nothing.
-- Measured 2026-08-19 while mutation-proving this migration: with the anon grant deleted the
-- function still showed `anon=X/postgres` and `has_function_privilege('anon', ...)` still returned
-- true, because a previous apply had granted it. After a real drop, anon correctly lost execute.
-- Migrations re-run on every deploy, so privileges must be rebuilt from scratch each time for the
-- same reason `03-security.sql` re-applies its revokes: that is what makes them self-healing.
drop function if exists market.aggregate_performance;

create function market.aggregate_performance(
  p_period               text     default '1y',
  p_group_by             text     default 'sector_id',
  p_country              text[]   default null,
  p_sector               text[]   default null,
  p_industry             text[]   default null,
  p_msci_tier            text[]   default null,
  p_msci_region          text[]   default null,
  p_ftse_tier            text[]   default null,
  p_income_group         text[]   default null,
  p_wb_region            text[]   default null,
  p_app_region           text[]   default null,
  p_cap_band             text[]   default null,
  p_style                text[]   default null,
  p_security_type        text[]   default array['equity'],
  p_min_market_cap_usd   numeric  default null,
  p_max_market_cap_usd   numeric  default null
)
returns table (
  bucket                     text,
  change_pct                 numeric,
  change_pct_equal           numeric,
  total_return_pct           numeric,
  constituents               integer,
  total_return_constituents  integer,
  bucket_securities          integer,
  weight_covered             numeric,
  as_of                      timestamptz
)
language sql
stable
-- SECURITY INVOKER (the default) on purpose: every `market` table carries RLS with an explicit
-- public select policy, so the caller's own grants decide what they can see. A definer function
-- here would quietly hand anon the owner's visibility.
as $$
with filtered as (
  select
    f.security_id,
    f.symbol,
    f.market_cap_usd,
    case p_group_by
      when 'sector_id'      then f.sector_id
      when 'industry'       then f.industry
      when 'country_iso2'   then f.country_iso2
      when 'msci_tier'      then f.msci_tier
      when 'msci_region'    then f.msci_region
      when 'ftse_tier'      then f.ftse_tier
      when 'ftse_region'    then f.ftse_region
      when 'income_group'   then f.income_group
      when 'wb_region'      then f.wb_region
      when 'app_region_id'  then f.app_region_id
      when 'cap_band'       then f.cap_band
      when 'style'          then f.style
      when 'security_type'  then f.security_type_code
      -- No `else`: an unrecognised group_by buckets everything as NULL and is dropped below, so a
      -- typo returns nothing rather than silently grouping the whole universe into one row.
    end as bucket
  from market.security_facets f
  where (p_security_type      is null or f.security_type_code = any(p_security_type))
    and (p_country            is null or f.country_iso2       = any(p_country))
    and (p_sector             is null or f.sector_id          = any(p_sector))
    and (p_industry           is null or f.industry           = any(p_industry))
    and (p_msci_tier          is null or f.msci_tier          = any(p_msci_tier))
    and (p_msci_region        is null or f.msci_region        = any(p_msci_region))
    and (p_ftse_tier          is null or f.ftse_tier          = any(p_ftse_tier))
    and (p_income_group       is null or f.income_group       = any(p_income_group))
    and (p_wb_region          is null or f.wb_region          = any(p_wb_region))
    and (p_app_region         is null or f.app_region_id      = any(p_app_region))
    and (p_cap_band           is null or f.cap_band           = any(p_cap_band))
    and (p_style              is null or f.style              = any(p_style))
    and (p_min_market_cap_usd is null or f.market_cap_usd    >= p_min_market_cap_usd)
    and (p_max_market_cap_usd is null or f.market_cap_usd    <= p_max_market_cap_usd)
),
joined as (
  -- LEFT join: securities with no performance row must still count toward `bucket_securities` and
  -- toward the DENOMINATOR of `weight_covered`. An inner join would make coverage identically 1
  -- and the guard would be decorative.
  select
    fl.bucket,
    fl.security_id,
    fl.market_cap_usd,
    p.change_pct,
    p.total_return_pct,
    p.as_of
  from filtered fl
  left join market.performance p
    on p.scope = 'instrument' and p.scope_id = fl.symbol and p.period = p_period
)
select
  j.bucket,
  -- Cap-weighted, over the securities that have BOTH a return and a comparable cap.
  round(
    sum(j.market_cap_usd * j.change_pct) filter (where j.change_pct is not null and j.market_cap_usd is not null)
    / nullif(sum(j.market_cap_usd) filter (where j.change_pct is not null and j.market_cap_usd is not null), 0)
  , 4) as change_pct,
  round(avg(j.change_pct) filter (where j.change_pct is not null), 4) as change_pct_equal,
  round(
    sum(j.market_cap_usd * j.total_return_pct) filter (where j.total_return_pct is not null and j.market_cap_usd is not null)
    / nullif(sum(j.market_cap_usd) filter (where j.total_return_pct is not null and j.market_cap_usd is not null), 0)
  , 4) as total_return_pct,
  count(*) filter (where j.change_pct is not null)::integer       as constituents,
  count(*) filter (where j.total_return_pct is not null)::integer as total_return_constituents,
  count(*)::integer                                               as bucket_securities,
  -- The share of the bucket's market cap that actually produced a number. Below ~0.5 the headline
  -- is describing a minority of the bucket by value and the UI should withhold it.
  round(
    sum(j.market_cap_usd) filter (where j.change_pct is not null)
    / nullif(sum(j.market_cap_usd), 0)
  , 4) as weight_covered,
  max(j.as_of) as as_of
from joined j
where j.bucket is not null
group by j.bucket;
$$;

comment on function market.aggregate_performance is
  'Weighted returns for ANY filtered slice of the universe, grouped by any facet — the aggregate the precomputed `performance` table cannot hold, because the bucket space is combinatorial. Cap-weighted and equal-weighted means are both returned, alongside constituents, bucket_securities and weight_covered so a thin bucket cannot render like a thick one. No dynamic SQL: p_group_by is a case over a whitelist, and an unrecognised value returns no rows.';

-- REVOKE FROM PUBLIC FIRST, THEN GRANT. Postgres grants EXECUTE on a new function to PUBLIC by
-- default, and `03-security.sql` only revokes TABLES in the `public` schema — so without this line
-- the grant below is decorative: every role could already execute it, and a test asserting "anon
-- can execute" would pass whether or not the grant existed. Measured while mutation-proving this
-- migration: deleting the grant entirely changed nothing. An explicit revoke makes the grant the
-- actual thing permitting access, which is the same discipline as the market tables' RLS policies
-- existing rather than relying on grants alone.
revoke execute on function market.aggregate_performance from public;
grant execute on function market.aggregate_performance to anon, authenticated, service_role;

notify pgrst, 'reload schema';
