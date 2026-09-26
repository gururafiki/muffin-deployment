do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_facets';
  if k = 'm' then execute 'drop materialized view if exists market.security_facets cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_facets cascade';
  end if;
end $$;
create materialized view market.security_facets as
WITH country_lens AS (
         SELECT classification_members.iso2,
            max(classification_members.group_id) FILTER (WHERE classification_members.scheme_id = 'msci'::text AND classification_members.lens = 'tier'::text) AS msci_tier,
            max(classification_members.group_id) FILTER (WHERE classification_members.scheme_id = 'msci'::text AND classification_members.lens = 'region'::text) AS msci_region,
            max(classification_members.group_id) FILTER (WHERE classification_members.scheme_id = 'ftse'::text AND classification_members.lens = 'tier'::text) AS ftse_tier,
            max(classification_members.group_id) FILTER (WHERE classification_members.scheme_id = 'ftse'::text AND classification_members.lens = 'region'::text) AS ftse_region,
            max(classification_members.group_id) FILTER (WHERE classification_members.scheme_id = 'world-bank'::text AND classification_members.lens = 'tier'::text) AS income_group,
            max(classification_members.group_id) FILTER (WHERE classification_members.scheme_id = 'world-bank'::text AND classification_members.lens = 'region'::text) AS wb_region
           FROM market.classification_members
          GROUP BY classification_members.iso2
        )
 SELECT sc.security_id,
    sc.symbol,
    sc.name,
    sc.security_type_code,
    sc.sector_id,
    sc.industry,
    sc.industry_code,
    sc.country_iso2,
    sc.country_name,
    c.region_id AS app_region_id,
    c.market AS country_market,
    cl.msci_tier,
    cl.msci_region,
    cl.ftse_tier,
    cl.ftse_region,
    cl.income_group,
    cl.wb_region,
    mc.market_cap_usd,
    sc.market_cap AS market_cap_native,
        CASE
            WHEN mc.market_cap_usd IS NULL THEN NULL::text
            WHEN mc.market_cap_usd >= '10000000000'::numeric THEN 'large'::text
            WHEN mc.market_cap_usd >= '2000000000'::numeric THEN 'mid'::text
            WHEN mc.market_cap_usd > 0::numeric THEN 'small'::text
            ELSE NULL::text
        END AS cap_band,
    cur.currency_code,
    cur.source AS currency_source,
    s.maturity_date,
    s.coupon_rate,
    s.coupon_kind_code,
    s.in_default,
    sc.is_tradeable,
    sty.style,
    sty.style_source,
    sty.style_confidence,
    sty.value_score,
    sty.cohort AS style_cohort,
    now() AS refreshed_at
   FROM market.security_current sc
     JOIN market.security s ON s.security_id = sc.security_id
     LEFT JOIN market.countries c ON c.iso2 = sc.country_iso2
     LEFT JOIN country_lens cl ON cl.iso2 = sc.country_iso2
     LEFT JOIN market.security_market_cap_usd mc ON mc.security_id = sc.security_id
     LEFT JOIN market.security_currency cur ON cur.security_id = sc.security_id
     LEFT JOIN market.security_style sty ON sty.security_id = sc.security_id;
