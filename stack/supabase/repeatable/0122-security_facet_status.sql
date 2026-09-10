do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_facet_status';
  if k = 'm' then execute 'drop materialized view if exists market.security_facet_status cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_facet_status cascade';
  end if;
end $$;
create view market.security_facet_status as
WITH b AS (
         SELECT f.security_id,
            f.security_type_code,
            f.symbol,
            f.symbol IS NOT NULL AS has_symbol,
            f.sector_id IS NOT NULL AS has_sector,
            f.industry_code IS NOT NULL AS has_industry,
            (EXISTS ( SELECT 1
                   FROM market.security_price p
                  WHERE p.security_id = f.security_id AND p.date > (CURRENT_DATE - 30))) AS has_price,
            (EXISTS ( SELECT 1
                   FROM market.performance pf
                  WHERE pf.scope = 'instrument'::text AND pf.scope_id = f.symbol)) AS has_performance,
            (EXISTS ( SELECT 1
                   FROM market.security_profile x_1
                  WHERE x_1.security_id = f.security_id)) AS has_profile,
            (EXISTS ( SELECT 1
                   FROM market.security_fundamentals x_1
                  WHERE x_1.security_id = f.security_id)) AS has_fundamentals,
            (EXISTS ( SELECT 1
                   FROM market.security_statement x_1
                  WHERE x_1.security_id = f.security_id)) AS has_statements,
            (EXISTS ( SELECT 1
                   FROM market.security_metric x_1
                  WHERE x_1.security_id = f.security_id)) AS has_metrics,
            s.price_history_from IS NOT NULL AS has_price_history,
            s.daily_history_from IS NOT NULL AS has_daily_history,
            (EXISTS ( SELECT 1
                   FROM market.news_security x_1
                  WHERE x_1.security_id = f.security_id)) AS has_news,
            (EXISTS ( SELECT 1
                   FROM market.security_officer x_1
                  WHERE x_1.security_id = f.security_id)) AS has_leadership,
            (EXISTS ( SELECT 1
                   FROM market.insider_trade x_1
                  WHERE x_1.security_id = f.security_id)) AS has_insider,
            (EXISTS ( SELECT 1
                   FROM market.security_filing x_1
                  WHERE x_1.security_id = f.security_id)) AS has_filings,
            (EXISTS ( SELECT 1
                   FROM market.security_corporate_action x_1
                  WHERE x_1.security_id = f.security_id AND x_1.kind = 'dividend'::text)) AS has_dividends,
            (EXISTS ( SELECT 1
                   FROM market.security_share_stats x_1
                  WHERE x_1.security_id = f.security_id)) AS has_share_stats,
            (EXISTS ( SELECT 1
                   FROM market.security_estimate x_1
                  WHERE x_1.security_id = f.security_id)) AS has_estimates,
            (EXISTS ( SELECT 1
                   FROM market.security_statement x_1
                  WHERE x_1.security_id = f.security_id AND x_1.period_type = 'quarter'::text)) AS has_quarters,
            s.sic IS NOT NULL AS has_sic,
            sd.capability = 'held'::text AS segment_capable,
            (EXISTS ( SELECT 1
                   FROM market.security_segment_spine x_1
                  WHERE x_1.security_id = f.security_id)) AS has_segments,
            (EXISTS ( SELECT 1
                   FROM market.security_segment_spine x_1
                  WHERE x_1.security_id = f.security_id AND x_1.kind = 'geography'::text)) AS has_segment_geography,
            (EXISTS ( SELECT 1
                   FROM market.security_taxonomy x_1
                  WHERE x_1.security_id = f.security_id AND (x_1.source_code = ANY (ARRAY['segment-revenue'::text, 'segment-profit'::text])))) AS has_weighted_industry
           FROM market.security_facets f
             LEFT JOIN market.security s ON s.security_id = f.security_id
             LEFT JOIN market.security_disclosure sd ON sd.security_id = f.security_id
        )
 SELECT b.security_id,
    b.security_type_code,
    x.facet,
    x.present,
    x.applicable,
    COALESCE(rf.required, false) AS required
   FROM b
     CROSS JOIN LATERAL ( VALUES ('symbol'::text,b.has_symbol,true), ('sector'::text,b.has_sector,true), ('industry'::text,b.has_industry,true), ('price'::text,b.has_price,true), ('performance'::text,b.has_performance,true), ('profile'::text,b.has_profile,true), ('fundamentals'::text,b.has_fundamentals,true), ('statements'::text,b.has_statements,true), ('metrics'::text,b.has_metrics,true), ('price_history'::text,b.has_price_history,true), ('daily_history'::text,b.has_daily_history,true), ('news'::text,b.has_news,true), ('leadership'::text,b.has_leadership,true), ('insider'::text,b.has_insider,true), ('filings'::text,b.has_filings,true), ('dividends'::text,b.has_dividends,true), ('share_stats'::text,b.has_share_stats,true), ('estimates'::text,b.has_estimates,true), ('quarters'::text,b.has_quarters,true), ('sic'::text,b.has_sic,b.segment_capable), ('segments'::text,b.has_segments,b.segment_capable), ('segment_geography'::text,b.has_segment_geography,b.segment_capable), ('weighted_industry'::text,b.has_weighted_industry,b.segment_capable)) x(facet, present, applicable)
     LEFT JOIN market.required_facet rf ON rf.security_type_code = b.security_type_code AND rf.facet = x.facet;
