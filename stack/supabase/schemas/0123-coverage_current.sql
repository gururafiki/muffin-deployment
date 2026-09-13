do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'coverage_current';
  if k = 'm' then execute 'drop materialized view if exists market.coverage_current cascade';
  elsif k = 'v' then execute 'drop view if exists market.coverage_current cascade';
  end if;
end $$;
create view market.coverage_current as
WITH base AS MATERIALIZED (
         SELECT f.security_id,
            f.security_type_code,
            f.symbol,
            f.country_iso2,
            f.sector_id,
            f.industry_code,
            f.cap_band,
            f.style,
            f.msci_tier,
            f.msci_region,
            f.income_group,
            f.currency_code,
            f.symbol IS NOT NULL AS has_symbol,
            f.sector_id IS NOT NULL AS has_sector,
            f.industry_code IS NOT NULL AS has_industry,
            p30.security_id IS NOT NULL AS has_price,
            p7.security_id IS NOT NULL AS priced_7d,
            p3.security_id IS NOT NULL AS priced_3d,
            pf.symbol IS NOT NULL AS has_performance,
            pr.security_id IS NOT NULL AS has_profile,
            fu.security_id IS NOT NULL AS has_fundamentals,
            st.security_id IS NOT NULL AS has_statements,
            mt.security_id IS NOT NULL AS has_metrics,
            f2.price_history_from IS NOT NULL AS has_price_history,
            f2.daily_history_from IS NOT NULL AS has_daily_history,
            nw.security_id IS NOT NULL AS has_news,
            of.security_id IS NOT NULL AS has_leadership,
            it.security_id IS NOT NULL AS has_insider,
            fl.security_id IS NOT NULL AS has_filings,
            dv.security_id IS NOT NULL AS has_dividends,
            ss.security_id IS NOT NULL AS has_share_stats,
            es.security_id IS NOT NULL AS has_estimates,
            qt.security_id IS NOT NULL AS has_quarters,
            f2.sic IS NOT NULL AS has_sic,
            sd.capability = 'held'::text AS segment_capable,
            sd.capability = 'resolvable'::text AS segment_resolvable,
            COALESCE(sd.segment_source, 'none'::text) AS segment_source,
            sg.security_id IS NOT NULL AS has_segments,
            gg.security_id IS NOT NULL AS has_segment_geography,
            wi.security_id IS NOT NULL AS has_weighted_industry
           FROM market.security_facets f
             LEFT JOIN ( SELECT DISTINCT security_price.security_id
                   FROM market.security_price
                  WHERE security_price.date > (CURRENT_DATE - 30)) p30 USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_price.security_id
                   FROM market.security_price
                  WHERE security_price.date > (CURRENT_DATE - 7)) p7 USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_price.security_id
                   FROM market.security_price
                  WHERE security_price.date > (CURRENT_DATE - 3)) p3 USING (security_id)
             LEFT JOIN ( SELECT DISTINCT performance.scope_id AS symbol
                   FROM market.performance
                  WHERE performance.scope = 'instrument'::text) pf ON pf.symbol = f.symbol
             LEFT JOIN market.security f2 USING (security_id)
             LEFT JOIN market.security_disclosure sd USING (security_id)
             LEFT JOIN ( SELECT DISTINCT news_security.security_id
                   FROM market.news_security) nw USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_officer.security_id
                   FROM market.security_officer) of USING (security_id)
             LEFT JOIN ( SELECT DISTINCT insider_trade.security_id
                   FROM market.insider_trade) it USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_filing.security_id
                   FROM market.security_filing) fl USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_corporate_action.security_id
                   FROM market.security_corporate_action
                  WHERE security_corporate_action.kind = 'dividend'::text) dv USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_share_stats.security_id
                   FROM market.security_share_stats) ss USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_estimate.security_id
                   FROM market.security_estimate) es USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_statement.security_id
                   FROM market.security_statement
                  WHERE security_statement.period_type = 'quarter'::text) qt USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_profile.security_id
                   FROM market.security_profile) pr USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_segment_spine.security_id
                   FROM market.security_segment_spine) sg USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_segment_spine.security_id
                   FROM market.security_segment_spine
                  WHERE security_segment_spine.kind = 'geography'::text) gg USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_taxonomy.security_id
                   FROM market.security_taxonomy
                  WHERE security_taxonomy.source_code = ANY (ARRAY['segment-revenue'::text, 'segment-profit'::text])) wi USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_fundamentals.security_id
                   FROM market.security_fundamentals) fu USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_statement.security_id
                   FROM market.security_statement) st USING (security_id)
             LEFT JOIN ( SELECT DISTINCT security_metric.security_id
                   FROM market.security_metric) mt USING (security_id)
        ), facet_status AS (
         SELECT base.security_id,
            base.security_type_code,
            'symbol'::text AS facet,
            base.has_symbol AS present
           FROM base
        UNION ALL
         SELECT base.security_id,
            base.security_type_code,
            'sector'::text,
            base.has_sector
           FROM base
        UNION ALL
         SELECT base.security_id,
            base.security_type_code,
            'industry'::text,
            base.has_industry
           FROM base
        UNION ALL
         SELECT base.security_id,
            base.security_type_code,
            'price'::text,
            base.has_price
           FROM base
        UNION ALL
         SELECT base.security_id,
            base.security_type_code,
            'performance'::text,
            base.has_performance
           FROM base
        UNION ALL
         SELECT base.security_id,
            base.security_type_code,
            'profile'::text,
            base.has_profile
           FROM base
        UNION ALL
         SELECT base.security_id,
            base.security_type_code,
            'fundamentals'::text,
            base.has_fundamentals
           FROM base
        UNION ALL
         SELECT base.security_id,
            base.security_type_code,
            'statements'::text,
            base.has_statements
           FROM base
        UNION ALL
         SELECT base.security_id,
            base.security_type_code,
            'metrics'::text,
            base.has_metrics
           FROM base
        ), all_facets AS (
         SELECT base.security_id,
            'symbol'::text AS facet,
            base.has_symbol AS present,
            true AS applicable
           FROM base
        UNION ALL
         SELECT base.security_id,
            'sector'::text,
            base.has_sector,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'industry'::text,
            base.has_industry,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'price'::text,
            base.has_price,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'performance'::text,
            base.has_performance,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'profile'::text,
            base.has_profile,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'fundamentals'::text,
            base.has_fundamentals,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'statements'::text,
            base.has_statements,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'metrics'::text,
            base.has_metrics,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'price_history'::text,
            base.has_price_history,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'daily_history'::text,
            base.has_daily_history,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'news'::text,
            base.has_news,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'leadership'::text,
            base.has_leadership,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'insider'::text,
            base.has_insider,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'filings'::text,
            base.has_filings,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'dividends'::text,
            base.has_dividends,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'share_stats'::text,
            base.has_share_stats,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'estimates'::text,
            base.has_estimates,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'quarters'::text,
            base.has_quarters,
            true
           FROM base
        UNION ALL
         SELECT base.security_id,
            'sic'::text,
            base.has_sic,
            base.segment_capable
           FROM base
        UNION ALL
         SELECT base.security_id,
            'segments'::text,
            base.has_segments,
            base.segment_capable
           FROM base
        UNION ALL
         SELECT base.security_id,
            'segment_geography'::text,
            base.has_segment_geography,
            base.segment_capable
           FROM base
        UNION ALL
         SELECT base.security_id,
            'weighted_industry'::text,
            base.has_weighted_industry,
            base.segment_capable
           FROM base
        ), richness AS (
         SELECT all_facets.security_id,
            count(*) FILTER (WHERE all_facets.present AND all_facets.applicable) AS present_facets,
            count(*) FILTER (WHERE all_facets.applicable) AS applicable_facets
           FROM all_facets
          GROUP BY all_facets.security_id
        ), completeness AS (
         SELECT fs.security_id,
            bool_and(fs.present OR NOT COALESCE(rf.required, false)) AS complete
           FROM facet_status fs
             LEFT JOIN market.required_facet rf ON rf.security_type_code = fs.security_type_code AND rf.facet = fs.facet
          GROUP BY fs.security_id
        ), dims AS (
         SELECT 'country'::text AS dimension,
            b.country_iso2 AS bucket,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'sector'::text,
            b.sector_id,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'industry'::text,
            b.industry_code,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'cap_band'::text,
            b.cap_band,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'style'::text,
            b.style,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'msci_tier'::text,
            b.msci_tier,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'msci_region'::text,
            b.msci_region,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'income_group'::text,
            b.income_group,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'currency'::text,
            b.currency_code,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'security_type'::text,
            b.security_type_code,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'segment_source'::text,
                CASE b.segment_source
                    WHEN 'none'::text THEN
                    CASE
                        WHEN b.segment_resolvable THEN 'resolvable'::text
                        ELSE 'none'::text
                    END
                    ELSE b.segment_source
                END AS segment_source,
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        UNION ALL
         SELECT 'country_sector'::text,
            (COALESCE(b.country_iso2, 'unknown'::text) || '|'::text) || COALESCE(b.sector_id, 'unknown'::text),
            b.security_id,
            b.security_type_code,
            b.symbol,
            b.country_iso2,
            b.sector_id,
            b.industry_code,
            b.cap_band,
            b.style,
            b.msci_tier,
            b.msci_region,
            b.income_group,
            b.currency_code,
            b.has_symbol,
            b.has_sector,
            b.has_industry,
            b.has_price,
            b.priced_7d,
            b.priced_3d,
            b.has_performance,
            b.has_profile,
            b.has_fundamentals,
            b.has_statements,
            b.has_metrics,
            b.has_price_history,
            b.has_daily_history,
            b.has_news,
            b.has_leadership,
            b.has_insider,
            b.has_filings,
            b.has_dividends,
            b.has_share_stats,
            b.has_estimates,
            b.has_quarters,
            b.has_sic,
            b.segment_capable,
            b.segment_resolvable,
            b.segment_source,
            b.has_segments,
            b.has_segment_geography,
            b.has_weighted_industry
           FROM base b
        )
 SELECT d.dimension,
    COALESCE(d.bucket, 'unknown'::text) AS bucket,
    d.security_type_code,
    count(*) AS securities,
    count(*) FILTER (WHERE d.segment_capable) AS segment_capable,
    count(*) FILTER (WHERE c.complete) AS complete,
    count(*) FILTER (WHERE d.has_symbol) AS with_symbol,
    count(*) FILTER (WHERE d.has_sector) AS with_sector,
    count(*) FILTER (WHERE d.has_industry) AS with_industry,
    count(*) FILTER (WHERE d.has_price) AS with_price,
    count(*) FILTER (WHERE d.has_performance) AS with_performance,
    count(*) FILTER (WHERE d.has_profile) AS with_profile,
    count(*) FILTER (WHERE d.has_fundamentals) AS with_fundamentals,
    count(*) FILTER (WHERE d.has_statements) AS with_statements,
    count(*) FILTER (WHERE d.has_metrics) AS with_metrics,
    count(*) FILTER (WHERE d.priced_3d) AS priced_3d,
    count(*) FILTER (WHERE d.priced_7d) AS priced_7d,
    count(*) FILTER (WHERE d.has_price) AS priced_30d,
    count(*) FILTER (WHERE d.has_price_history) AS with_price_history,
    count(*) FILTER (WHERE d.has_daily_history) AS with_daily_history,
    count(*) FILTER (WHERE d.has_news) AS with_news,
    count(*) FILTER (WHERE d.has_leadership) AS with_leadership,
    count(*) FILTER (WHERE d.has_insider) AS with_insider,
    count(*) FILTER (WHERE d.has_filings) AS with_filings,
    count(*) FILTER (WHERE d.has_dividends) AS with_dividends,
    count(*) FILTER (WHERE d.has_share_stats) AS with_share_stats,
    count(*) FILTER (WHERE d.has_estimates) AS with_estimates,
    count(*) FILTER (WHERE d.has_quarters) AS with_quarters,
    count(*) FILTER (WHERE d.has_sic) AS with_sic,
    count(*) FILTER (WHERE d.has_segments) AS with_segments,
    count(*) FILTER (WHERE d.has_segment_geography) AS with_segment_geography,
    count(*) FILTER (WHERE d.has_weighted_industry) AS with_weighted_industry,
    sum(r.present_facets) AS present_facets,
    sum(r.applicable_facets) AS applicable_facets
   FROM dims d
     JOIN completeness c USING (security_id)
     JOIN richness r USING (security_id)
  GROUP BY d.dimension, (COALESCE(d.bucket, 'unknown'::text)), d.security_type_code;
