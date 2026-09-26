-- FIVE READERS OF THE RETIRED PRICE TABLE MOVE TO `price_bar`.
--
-- The D2 cutover (20260912000000) moved `price_series` and `performance` onto the Dagster tables
-- and retired the resources that wrote `market.security_price`. Five other readers were never
-- re-pointed, and measured on 2026-09-26 they had been reading a table frozen at its 2026-09-11
-- bar for fifteen days:
--
--   * `security_ratio_series` — the P/E, P/S, P/B and price-to-FCF charts. Every ratio stopped at
--     09-11, and a security added since has no ratio chart at all, because it has no bar there.
--   * `coverage_current` — the p30/p7/p3 price-freshness facets, decaying toward zero while the
--     prices themselves were current.
--   * `security_facet_status` — `has_price`, the same fact per security.
--   * `data_defect` — `contradicted_negative_cache` compared marks with bars that no longer moved.
--   * `sample_universe` — `fresh_hours.security_price.date`, the single most load-bearing freshness
--     number, reporting the frozen bar as the newest price in the universe. The metric is renamed
--     `fresh_hours.price_bar.trade_date`, because a number is not what its name says otherwise; no
--     panel or rule reads the old name (checked).
--
-- Each is a like-for-like source swap, nothing else:
--
--   * The ratio view keeps its `grain` contract with the shape `price_series` already uses: a daily
--     arm bounded to 400 days (the old table's daily window was the same ~400) and a weekly arm,
--     the last bar of each week over the whole history. The app asks for one symbol and one grain,
--     newest first with a limit (`use-ratio-series.ts`), and both arms stay bounded for it.
--   * `quote_currency` is still `security.currency_code`, exactly as before. Whether a bar's own
--     `price_bar.currency_code` is the better label is a separate question, not smuggled in here.
--   * No index leads on `price_bar.trade_date`, so every whole-universe read is bounded by date,
--     which prunes it to the current yearly partition.
--
-- CREATE OR REPLACE throughout, never drop-and-create: the columns are unchanged, so the grants
-- and the dependents survive, where a dropped view loses its ACL (the app's read path, once).
--
-- `pending_prices` also reads the old table. It is not touched here: its resource was retired on
-- 09-12 and it is dropped with the rest of that family's backlog views.

-- security_ratio_series
create or replace view market.security_ratio_series as
WITH spans AS (
         SELECT m.security_id,
            m.metric_code,
            m.value,
            m.currency_code,
            m.as_of,
            lead(m.as_of) OVER (PARTITION BY m.security_id, m.metric_code ORDER BY m.as_of) AS next_as_of
           FROM market.security_metric m
             JOIN market.metric mt ON mt.code = m.metric_code
          WHERE m.period_type =
                CASE
                    WHEN mt.is_flow THEN 'ttm'::text
                    ELSE 'quarter'::text
                END AND (m.metric_code = ANY (ARRAY['eps_diluted'::text, 'revenue'::text, 'total_equity'::text, 'free_cash_flow'::text, 'net_income'::text, 'shares_diluted'::text, 'total_assets'::text]))
        ), fx AS (
         SELECT r.currency_code,
            r.usd_per_unit,
            r.as_of,
            lead(r.as_of) OVER (PARTITION BY r.currency_code ORDER BY r.as_of) AS next_as_of
           FROM market.fx_rate r
        ), bars AS (
         SELECT ss.symbol,
            pb.security_id,
            pb.trade_date AS date,
            pb.close,
            'daily'::text AS grain,
            s.currency_code AS quote_currency,
            s.reporting_currency
           FROM market.price_bar pb
             JOIN market.symbol_security ss ON ss.security_id = pb.security_id
             JOIN market.security s ON s.security_id = pb.security_id
          WHERE pb.trade_date > (CURRENT_DATE - 400)
        UNION ALL
         SELECT w.symbol,
            w.security_id,
            w.date,
            w.close,
            'weekly'::text AS grain,
            s.currency_code AS quote_currency,
            s.reporting_currency
           FROM ( SELECT DISTINCT ON (ss.symbol, (date_trunc('week'::text, pb.trade_date::timestamp with time zone))) ss.symbol,
                    pb.security_id,
                    pb.trade_date AS date,
                    pb.close
                   FROM market.price_bar pb
                     JOIN market.symbol_security ss ON ss.security_id = pb.security_id
                  ORDER BY ss.symbol, (date_trunc('week'::text, pb.trade_date::timestamp with time zone)), pb.trade_date DESC) w
             JOIN market.security s ON s.security_id = w.security_id
        ), joined AS (
         SELECT b.symbol,
            b.security_id,
            b.date,
            b.close,
            b.grain,
            b.quote_currency,
            b.reporting_currency,
            max(
                CASE
                    WHEN sp.metric_code = 'eps_diluted'::text THEN sp.value
                    ELSE NULL::numeric
                END) AS eps,
            max(
                CASE
                    WHEN sp.metric_code = 'revenue'::text THEN sp.value
                    ELSE NULL::numeric
                END) AS revenue,
            max(
                CASE
                    WHEN sp.metric_code = 'total_equity'::text THEN sp.value
                    ELSE NULL::numeric
                END) AS equity,
            max(
                CASE
                    WHEN sp.metric_code = 'free_cash_flow'::text THEN sp.value
                    ELSE NULL::numeric
                END) AS fcf,
            max(
                CASE
                    WHEN sp.metric_code = 'net_income'::text THEN sp.value
                    ELSE NULL::numeric
                END) AS net_income,
            max(
                CASE
                    WHEN sp.metric_code = 'shares_diluted'::text THEN sp.value
                    ELSE NULL::numeric
                END) AS shares,
            max(
                CASE
                    WHEN sp.metric_code = 'total_assets'::text THEN sp.value
                    ELSE NULL::numeric
                END) AS assets,
            max(sp.currency_code) AS metric_currency
           FROM bars b
             JOIN spans sp ON sp.security_id = b.security_id AND b.date >= sp.as_of AND (sp.next_as_of IS NULL OR b.date < sp.next_as_of)
          GROUP BY b.symbol, b.security_id, b.date, b.close, b.grain, b.quote_currency, b.reporting_currency
        ), resolved AS (
         SELECT j.symbol,
            j.security_id,
            j.date,
            j.close,
            j.grain,
            j.quote_currency,
            j.reporting_currency,
            j.eps,
            j.revenue,
            j.equity,
            j.fcf,
            j.net_income,
            j.shares,
            j.assets,
            j.metric_currency,
            COALESCE(j.metric_currency, j.reporting_currency) AS report_currency
           FROM joined j
        ), priced AS (
         SELECT r.symbol,
            r.security_id,
            r.date,
            r.close,
            r.grain,
            r.quote_currency,
            r.reporting_currency,
            r.eps,
            r.revenue,
            r.equity,
            r.fcf,
            r.net_income,
            r.shares,
            r.assets,
            r.metric_currency,
            r.report_currency,
                CASE
                    WHEN r.report_currency = 'USD'::text THEN 1::numeric
                    ELSE fr.usd_per_unit
                END AS report_usd,
                CASE
                    WHEN r.quote_currency = 'USD'::text THEN 1::numeric
                    ELSE fq.usd_per_unit
                END AS quote_usd
           FROM resolved r
             LEFT JOIN fx fr ON fr.currency_code = r.report_currency AND r.date >= fr.as_of AND (fr.next_as_of IS NULL OR r.date < fr.next_as_of)
             LEFT JOIN fx fq ON fq.currency_code = r.quote_currency AND r.date >= fq.as_of AND (fq.next_as_of IS NULL OR r.date < fq.next_as_of)
        ), converted AS (
         SELECT p.symbol,
            p.security_id,
            p.date,
            p.close,
            p.grain,
            p.quote_currency,
            p.reporting_currency,
            p.eps,
            p.revenue,
            p.equity,
            p.fcf,
            p.net_income,
            p.shares,
            p.assets,
            p.metric_currency,
            p.report_currency,
            p.report_usd,
            p.quote_usd,
            p.report_currency IS NOT NULL AND p.quote_currency IS NOT NULL AND p.report_currency = p.quote_currency AS same_currency,
            p.report_currency IS NOT NULL AND p.quote_currency IS NOT NULL AND p.report_currency <> p.quote_currency AND p.report_usd IS NOT NULL AND p.quote_usd IS NOT NULL AND p.quote_usd > 0::numeric AS convertible,
                CASE
                    WHEN p.report_currency = p.quote_currency THEN 1::numeric
                    WHEN p.report_usd IS NOT NULL AND p.quote_usd IS NOT NULL AND p.quote_usd > 0::numeric THEN p.report_usd / p.quote_usd
                    ELSE NULL::numeric
                END AS fx
           FROM priced p
        )
 SELECT symbol,
    security_id,
    date,
    grain,
    close,
    report_currency,
    quote_currency,
    same_currency OR convertible AS currency_comparable,
    convertible AS fx_converted,
        CASE
            WHEN fx IS NOT NULL AND (eps * fx) > 0::numeric THEN round(close / (eps * fx), 4)
            ELSE NULL::numeric
        END AS pe_ratio,
        CASE
            WHEN fx IS NOT NULL AND revenue > 0::numeric AND shares > 0::numeric THEN round(close / (revenue * fx / shares), 4)
            ELSE NULL::numeric
        END AS ps_ratio,
        CASE
            WHEN fx IS NOT NULL AND equity > 0::numeric AND shares > 0::numeric THEN round(close / (equity * fx / shares), 4)
            ELSE NULL::numeric
        END AS pb_ratio,
        CASE
            WHEN fx IS NOT NULL AND fcf > 0::numeric AND shares > 0::numeric THEN round(close / (fcf * fx / shares), 4)
            ELSE NULL::numeric
        END AS price_to_fcf,
        CASE
            WHEN fx IS NOT NULL AND (eps * fx) > 0::numeric THEN round(eps * fx / close * 100::numeric, 4)
            ELSE NULL::numeric
        END AS earnings_yield_pct,
        CASE
            WHEN fx IS NOT NULL AND fcf > 0::numeric AND shares > 0::numeric THEN round(fcf * fx / shares / close * 100::numeric, 4)
            ELSE NULL::numeric
        END AS fcf_yield_pct,
        CASE
            WHEN revenue > 0::numeric THEN round(net_income / revenue * 100::numeric, 4)
            ELSE NULL::numeric
        END AS net_margin_pct,
        CASE
            WHEN equity > 0::numeric THEN round(net_income / equity * 100::numeric, 4)
            ELSE NULL::numeric
        END AS roe_pct,
        CASE
            WHEN assets > 0::numeric THEN round(net_income / assets * 100::numeric, 4)
            ELSE NULL::numeric
        END AS roa_pct
   FROM converted;

-- coverage_current
create or replace view market.coverage_current as
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
             LEFT JOIN ( SELECT DISTINCT price_bar.security_id
                   FROM market.price_bar
                  WHERE price_bar.trade_date > (CURRENT_DATE - 30)) p30 USING (security_id)
             LEFT JOIN ( SELECT DISTINCT price_bar.security_id
                   FROM market.price_bar
                  WHERE price_bar.trade_date > (CURRENT_DATE - 7)) p7 USING (security_id)
             LEFT JOIN ( SELECT DISTINCT price_bar.security_id
                   FROM market.price_bar
                  WHERE price_bar.trade_date > (CURRENT_DATE - 3)) p3 USING (security_id)
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

-- security_facet_status
create or replace view market.security_facet_status as
WITH b AS (
         SELECT f.security_id,
            f.security_type_code,
            f.symbol,
            f.symbol IS NOT NULL AS has_symbol,
            f.sector_id IS NOT NULL AS has_sector,
            f.industry_code IS NOT NULL AS has_industry,
            (EXISTS ( SELECT 1
                   FROM market.price_bar p
                  WHERE p.security_id = f.security_id AND p.trade_date > (CURRENT_DATE - 30))) AS has_price,
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

-- data_defect
create or replace view market.data_defect as
SELECT 'placeholder_cusip'::text AS defect,
    count(*) AS n,
    'security_identifier rows with the all-zero CUSIP placeholder'::text AS detail
   FROM market.security_identifier
  WHERE security_identifier.kind_code = 'cusip'::text AND security_identifier.value = '000000000'::text
UNION ALL
 SELECT 'placeholder_isin'::text AS defect,
    count(*) AS n,
    'security_identifier rows with the all-zero ISIN placeholder'::text AS detail
   FROM market.security_identifier
  WHERE security_identifier.kind_code = 'isin'::text AND security_identifier.value = '000000000000'::text
UNION ALL
 SELECT 'duplicate_constituents'::text AS defect,
    COALESCE(sum(q.rows_ - q.distinct_), 0::numeric) AS n,
    'sector_constituents rows beyond one per security, across ALL sectors'::text AS detail
   FROM ( SELECT sector_constituents.sector_id,
            count(*) AS rows_,
            count(DISTINCT sector_constituents.security_id) AS distinct_
           FROM market.sector_constituents
          GROUP BY sector_constituents.sector_id) q
UNION ALL
 SELECT 'returns_at_minus_100'::text AS defect,
    count(*) AS n,
    'performance rows at exactly -100% — a zero close became a total loss'::text AS detail
   FROM market.performance
  WHERE performance.scope = 'instrument'::text AND performance.change_pct = '-100'::integer::numeric
UNION ALL
 SELECT 'frozen_series'::text AS defect,
    count(*) AS n,
    'symbols whose FRESH refresh is 0.00% on every period it produced (3+ periods)'::text AS detail
   FROM ( SELECT performance.scope_id
           FROM market.performance
          WHERE performance.scope = 'instrument'::text AND performance.as_of > (now() - '2 days'::interval)
          GROUP BY performance.scope_id
         HAVING count(*) FILTER (WHERE performance.change_pct = 0::numeric) >= 3 AND count(*) FILTER (WHERE performance.change_pct IS NOT NULL AND performance.change_pct <> 0::numeric) = 0) q
UNION ALL
 SELECT 'contradicted_negative_cache'::text AS defect,
    count(*) AS n,
    'securities marked as having no returns while holding recent bars that MOVE'::text AS detail
   FROM market.security s
  WHERE s.performance_missing_at IS NOT NULL AND (( SELECT count(DISTINCT p.close) AS count
           FROM market.price_bar p
          WHERE p.security_id = s.security_id AND p.trade_date > (CURRENT_DATE - 30))) > 1 AND (EXISTS ( SELECT 1
           FROM market.price_bar p
          WHERE p.security_id = s.security_id AND p.trade_date > (CURRENT_DATE - 7)))
UNION ALL
 SELECT 'country_with_no_symbols'::text AS defect,
    count(*) AS n,
    'countries with 20+ equities and not one provider symbol'::text AS detail
   FROM ( SELECT s.country_iso2
           FROM market.security s
          WHERE s.security_type_code = 'equity'::text AND s.country_iso2 IS NOT NULL
          GROUP BY s.country_iso2
         HAVING count(*) >= 20 AND NOT (EXISTS ( SELECT 1
                   FROM market.security s2
                  WHERE s2.country_iso2 = s.country_iso2 AND ((EXISTS ( SELECT 1
                           FROM market.security_provider_symbol sp
                          WHERE sp.security_id = s2.security_id)) OR (EXISTS ( SELECT 1
                           FROM market.security_identifier i
                          WHERE i.security_id = s2.security_id AND i.kind_code = 'ticker'::text)))))) q
UNION ALL
 SELECT 'queued_but_already_done'::text AS defect,
    count(*) AS n,
    'securities in pending_industry that already have a level-2 industry'::text AS detail
   FROM market.pending_industry pi
  WHERE (EXISTS ( SELECT 1
           FROM market.security_taxonomy st
             JOIN market.taxonomy_node tn ON tn.node_id = st.node_id
          WHERE st.security_id = pi.security_id AND tn.level = 2))
UNION ALL
 SELECT 'extreme_1y_returns'::text AS defect,
    count(*) AS n,
    'GAUGE not an invariant: 1y returns >= +1000%, expected non-zero and stable'::text AS detail
   FROM market.performance
  WHERE performance.scope = 'instrument'::text AND performance.period = '1y'::text AND performance.change_pct >= 1000::numeric;

-- sample_universe
CREATE OR REPLACE FUNCTION market.sample_universe()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  r     record;
  n     bigint;
  ts    timestamptz := now();
  taken integer := 0;
  newest timestamptz;
begin
  perform set_config('statement_timeout', '30s', true);

  -- ESTIMATED rows, exact on-disk size. `reltuples` is -1 for a relation never analysed
  -- (Postgres 14+ distinguishes that from a genuine zero), so it is skipped rather than recorded
  -- as -1. Exact counting all 63 tables was 10,252 ms cold and bought nothing a gauge needs.
  for r in
    select c.relname as tbl, c.reltuples as est, pg_total_relation_size(c.oid) as bytes
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'market' and c.relkind = 'r'
     order by c.relname
  loop
    if r.est >= 0 then
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, 'rows_estimate.' || r.tbl, r.est) on conflict do nothing;
      taken := taken + 1;
    end if;
    insert into market.universe_sample (sampled_at, metric, value)
         values (ts, 'bytes.' || r.tbl, r.bytes) on conflict do nothing;
    taken := taken + 1;
  end loop;

  -- Negative-cache populations. EXACT, and they have to be: a 20% jump is an alert, and an
  -- estimate's error bar is wider than that.
  for r in
    select c.relname as tbl, a.attname as col
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid
     where ns.nspname = 'market' and c.relkind = 'r'
       and a.attnum > 0 and not a.attisdropped and a.attname like '%\_missing\_at'
     order by c.relname, a.attname
  loop
    begin
      execute format('select count(*) from market.%I where %I is not null', r.tbl, r.col) into n;
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, format('missing.%s.%s', r.tbl, r.col), n) on conflict do nothing;

      -- ABOUT TO LAPSE. The negative caches expire at 30 days, so a mark older than 23 days is
      -- work returning to a backlog within the week. Without this the backlog simply jumps and
      -- nothing explains it.
      execute format(
        'select count(*) from market.%I where %I is not null and %I < now() - interval ''23 days''',
        r.tbl, r.col, r.col) into n;
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, format('expiring.%s.%s', r.tbl, r.col), n) on conflict do nothing;
      taken := taken + 2;
    exception when others then null;
    end;
  end loop;

  -- FRESHNESS. The age in hours of the newest row per timestamped table, discovered rather than
  -- listed — 449 ms for all of them, slowest 141 ms. An AGE rather than a timestamp so a panel
  -- can threshold it without knowing when it was sampled.
  for r in
    select c.relname as tbl, a.attname as col
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid
     where ns.nspname = 'market' and c.relkind = 'r'
       and a.attnum > 0 and not a.attisdropped and a.attname in ('as_of', 'fetched_at')
     order by c.relname, a.attname
  loop
    begin
      execute format('select max(%I) from market.%I', r.col, r.tbl) into newest;
      if newest is not null then
        insert into market.universe_sample (sampled_at, metric, value)
             values (ts, format('fresh_hours.%s.%s', r.tbl, r.col),
                     extract(epoch from (ts - newest)) / 3600.0) on conflict do nothing;
        taken := taken + 1;
      end if;
    exception when others then null;
    end;
  end loop;

  -- The newest price bar, the single most load-bearing freshness number here. From `price_bar`
  -- since 2026-09-26: `security_price` was retired on 09-12 and this kept reading it for two
  -- weeks, reporting its frozen 09-11 bar as the newest price in the universe. No index leads on
  -- `trade_date`, so the window is what keeps it cheap: it prunes to the current partition.
  begin
    select max(trade_date)::timestamptz into newest from market.price_bar
     where trade_date > current_date - 30;
    if newest is not null then
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, 'fresh_hours.price_bar.trade_date',
                   extract(epoch from (ts - newest)) / 3600.0) on conflict do nothing;
      taken := taken + 1;
    end if;
  exception when others then null;
  end;

  -- STALENESS AS THE APP SEES IT. `performance.stale_after` is the pipeline's own judgement about
  -- when a number stops being good; this is how much of it has passed that point. 76,209 today.
  begin
    select count(*) into n from market.performance where stale_after < now();
    insert into market.universe_sample (sampled_at, metric, value)
         values (ts, 'stale.performance', n) on conflict do nothing;
    taken := taken + 1;
  exception when others then null;
  end;

  -- GROWTH. Whether the universe is still being extended — i.e. whether `promote-wave` and the
  -- fund ingest are doing anything. A flat line here with a healthy backlog means promotion has
  -- stopped, which nothing else reports.
  begin
    select count(*) into n from market.security where first_seen_at > now() - interval '7 days';
    insert into market.universe_sample (sampled_at, metric, value)
         values (ts, 'growth.securities_7d', n) on conflict do nothing;
    select count(*) into n from market.security where first_seen_at > now() - interval '30 days';
    insert into market.universe_sample (sampled_at, metric, value)
         values (ts, 'growth.securities_30d', n) on conflict do nothing;
    taken := taken + 2;
  exception when others then null;
  end;

  -- THE SCHEDULER ITSELF. With GitHub Actions gone, pg_cron is the only thing driving the
  -- pipeline and its failure is silent — the data just stops. `minutes_since_tick` is what the
  -- "scheduler has gone silent" alert watches; the rotation fires every 5 minutes, so anything
  -- past 30 means it has stopped.
  begin
    insert into market.universe_sample (sampled_at, metric, value)
    select ts, m, v from (
      select 'scheduler.ticks_1h' as m, ticks_1h::numeric as v from market.scheduler_health()
      union all select 'scheduler.failed_1h', failed_1h from market.scheduler_health()
      union all select 'scheduler.minutes_since_tick', minutes_since_tick from market.scheduler_health()
    ) s where v is not null
    on conflict do nothing;
    taken := taken + 3;
  exception when others then null;   -- no pg_cron in the test image
  end;

  -- EXACT, because market-verify.yml asserts floors on exactly these.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, m, v from (
    select 'equities' as m, count(*)::numeric as v from market.security where security_type_code = 'equity'
    union all select 'identifiers.isin',   count(*) from market.security_identifier where kind_code = 'isin'
    union all select 'identifiers.ticker', count(*) from market.security_identifier where kind_code = 'ticker'
    union all select 'identifiers.cusip',  count(*) from market.security_identifier where kind_code = 'cusip'
    union all select 'tracked_funds.enabled',  count(*) from market.tracked_fund where enabled = true
    union all select 'tracked_funds.ingested', count(*) from market.tracked_fund where last_report_date is not null
  ) s
  on conflict do nothing;

  -- BREADTH, WHICH IS THE NUMBER THAT GATES THE SEGMENT FEATURE. Companies REACHED, not facts
  -- written: while `pending_segments` was ordered by fund weight the queue walked one company's
  -- whole 20-year history before starting the next, so 440 parsed filings belonged to fourteen
  -- securities — and every other signal (`written`, `remaining`, `ok`, the reconciliation guard)
  -- said healthy, because the rows being written were correct. They were the wrong rows first.
  -- Nothing here could see it, because nothing counted companies.
  --
  -- `count(distinct security_id)` over `security_segment` measured 486 ms at 1.92M rows, which is
  -- affordable twice an hour. It is EXACT rather than a `reltuples` estimate because the whole
  -- point is a small integer (14 against 3,500) where a few percent of error is the entire signal.
  begin
    insert into market.universe_sample (sampled_at, metric, value)
    select ts, m, v from (
      select 'segments.companies' as m, count(distinct security_id)::numeric as v
        from market.security_segment
      union all
      select 'segments.filings_parsed', count(*)
        from market.security_filing where segments_parsed_at is not null
      union all
      select 'segments.comparable_concepts', count(*) from (
        select 1 from market.security_segment_spine
         where concept_code is not null
         group by concept_code having count(distinct security_id) >= 2) c
    ) s
    on conflict do nothing;
    taken := taken + 3;
  exception when others then null;   -- the spine may not exist yet on a partially-applied database
  end;

  return taken + 6;
end $function$;

