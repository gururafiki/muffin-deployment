-- A WELL-COVERED NUMBER CAN STILL BE TWO COMPANIES, AND NOTHING IN THE RESPONSE SAID SO.
--
-- Found 2026-08-19 by interrogating the RPC's own output rather than by a failure. Asking for
-- 1-year sector returns filtered to developed / large-cap / value:
--
--   information-technology   cap-weighted +327.40%   constituents 77/80   weight_covered 0.98
--
-- Every guard says that number is trustworthy: 80 securities, 98% of the bucket by value priced.
-- It is also arithmetically correct. And it is two companies:
--
--   MU    Micron Technology   cap $1,088.7bn   1y   +670.8%   ->  127.66pp of the 327.40
--   SNDK  Sandisk             cap $  185.6bn   1y +3,471.6%   ->  112.62pp
--   INTC  Intel               cap $  546.2bn   1y   +282.0%   ->   26.93pp
--   ...74 others                                              ->   the remaining 60pp
--
-- The returns are REAL — checked, because a number that large is usually a broken price series.
-- MU has 276 smooth bars (x8.61 over the year, largest single-bar move x1.19); SNDK x42.06 with a
-- largest bar of x1.28; WDC x8.01; INTC x4.47. The documented threshold for an illegitimate
-- discontinuity in this pipeline is x6 IN ONE BAR, and nothing here is close. This is a real
-- memory/storage cycle, not corruption.
--
-- So the defect is not the arithmetic, it is what the response omits. `weight_covered` answers
-- "how much of this bucket produced a number" — a COMPLETENESS question. It cannot answer "is this
-- number broad-based", a CONCENTRATION question, and at 0.98 it actively suggests the answer is
-- yes. A reader seeing +327% for a sector concludes the sector rose 327%.
--
-- ── WHY CONTRIBUTION SHARE AND NOT WEIGHT SHARE ──────────────────────────────────────────────
--
-- Weight share alone misses it. MU is 19% of the bucket by market cap, which looks unremarkable —
-- but SNDK is only 3.2% by cap and supplies 112 of the 327 points, because its return is 3,471%.
-- Concentration in a WEIGHTED MEAN lives in `weight x return`, not in either factor alone.
--
-- `top_contributor_share` is therefore the largest single |w*r| as a fraction of the summed |w*r|.
-- Absolute values, so a large negative contribution counts as influence rather than cancelling a
-- positive one — "what would move most if this row were wrong" is the question being asked.
-- `top_contributor` names it, because "driven by MU" is actionable in a way that a ratio is not.
--
-- This is the same discipline as `constituents` and `weight_covered` existing at all, and as the
-- country page putting a sector's coverage in the LABEL: a number that cannot be interrogated gets
-- believed. It does NOT suppress anything — +327% is the correct cap-weighted answer and callers
-- that want the broad-based view already have `change_pct_equal` (+50.07% here, and the gap
-- between the two was the first hint).

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
  top_contributor            text,
  top_contributor_share      numeric,
  as_of                      timestamptz
)
language sql
stable
-- SECURITY INVOKER (the default) on purpose: every `market` relation carries RLS or an explicit
-- grant, so the caller's own privileges decide what they can see.
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
    fl.symbol,
    fl.market_cap_usd,
    p.change_pct,
    p.total_return_pct,
    p.as_of,
    -- The row's INFLUENCE on the weighted mean. Null unless it has both factors.
    case when p.change_pct is not null and fl.market_cap_usd is not null
         then fl.market_cap_usd * p.change_pct end as contribution
  from filtered fl
  left join market.performance p
    on p.scope = 'instrument' and p.scope_id = fl.symbol and p.period = p_period
)
select
  j.bucket,
  round(
    sum(j.contribution) filter (where j.contribution is not null)
    / nullif(sum(j.market_cap_usd) filter (where j.contribution is not null), 0)
  , 4) as change_pct,
  round(avg(j.change_pct) filter (where j.change_pct is not null), 4) as change_pct_equal,
  round(
    sum(j.market_cap_usd * j.total_return_pct) filter (where j.total_return_pct is not null and j.market_cap_usd is not null)
    / nullif(sum(j.market_cap_usd) filter (where j.total_return_pct is not null and j.market_cap_usd is not null), 0)
  , 4) as total_return_pct,
  count(*) filter (where j.change_pct is not null)::integer       as constituents,
  count(*) filter (where j.total_return_pct is not null)::integer as total_return_constituents,
  count(*)::integer                                               as bucket_securities,
  round(
    sum(j.market_cap_usd) filter (where j.change_pct is not null)
    / nullif(sum(j.market_cap_usd), 0)
  , 4) as weight_covered,
  -- The single security supplying the most of this number, and how much of it. Ordered by ABSOLUTE
  -- contribution: a large negative mover is just as much "what this number is made of" as a large
  -- positive one, and signed ordering would hide it behind the positives.
  (array_agg(j.symbol order by abs(j.contribution) desc nulls last)
     filter (where j.contribution is not null))[1] as top_contributor,
  round(
    max(abs(j.contribution)) filter (where j.contribution is not null)
    / nullif(sum(abs(j.contribution)) filter (where j.contribution is not null), 0)
  , 4) as top_contributor_share,
  max(j.as_of) as as_of
from joined j
where j.bucket is not null
group by j.bucket;
$$;

comment on function market.aggregate_performance is
  'Weighted returns for ANY filtered slice of the universe, grouped by any facet. Returns cap-weighted AND equal-weighted means, plus everything needed to interrogate the number: constituents, bucket_securities, weight_covered (completeness) and top_contributor/top_contributor_share (concentration). The two are different questions — measured 2026-08-19, developed large-cap value IT returned +327.40% at 98% coverage, of which 240 points came from two companies. No dynamic SQL: p_group_by is a case over a whitelist.';

revoke execute on function market.aggregate_performance from public;
grant execute on function market.aggregate_performance to anon, authenticated, service_role;

notify pgrst, 'reload schema';
