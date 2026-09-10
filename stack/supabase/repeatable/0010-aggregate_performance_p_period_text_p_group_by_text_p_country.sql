CREATE OR REPLACE FUNCTION market.aggregate_performance(p_period text DEFAULT '1y'::text, p_group_by text DEFAULT 'sector_id'::text, p_country text[] DEFAULT NULL::text[], p_sector text[] DEFAULT NULL::text[], p_industry text[] DEFAULT NULL::text[], p_msci_tier text[] DEFAULT NULL::text[], p_msci_region text[] DEFAULT NULL::text[], p_ftse_tier text[] DEFAULT NULL::text[], p_income_group text[] DEFAULT NULL::text[], p_wb_region text[] DEFAULT NULL::text[], p_app_region text[] DEFAULT NULL::text[], p_cap_band text[] DEFAULT NULL::text[], p_style text[] DEFAULT NULL::text[], p_security_type text[] DEFAULT ARRAY['equity'::text], p_min_market_cap_usd numeric DEFAULT NULL::numeric, p_max_market_cap_usd numeric DEFAULT NULL::numeric)
 RETURNS TABLE(bucket text, change_pct numeric, change_pct_equal numeric, total_return_pct numeric, constituents integer, total_return_constituents integer, bucket_securities integer, weight_covered numeric, top_contributor text, top_contributor_share numeric, as_of timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
with filtered as (
  select
    f.security_id,
    f.symbol,
    f.market_cap_usd,
    case p_group_by
      when 'sector_id'      then f.sector_id
      when 'industry'       then f.industry
      when 'industry_code'  then f.industry_code
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
    -- Matches EITHER spelling: the stable code is what a saved filter should carry, but a
    -- caller holding a display name must not silently get an empty bucket.
    and (p_industry           is null or f.industry = any(p_industry) or f.industry_code = any(p_industry))
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
$function$;
