-- A RATIO TAKES ITS QUOTE CURRENCY FROM THE BAR IT DIVIDES.
--
-- WHY. `security_ratio_series.quote_currency` came from `security.currency_code`, which holds the
-- currency of a line a US fund holds (N-PORT) or a metrics response's REPORTING currency. Neither
-- is the currency of the line the price lane prices. Measured 2026-10-05 against Yahoo's
-- `meta.currency`: ALG.KW served a P/E of 12,305 (fils read as dinars), Azrieli 2,547 (agorot as
-- shekels), Lenovo 222.6 (HKD read as USD, 7.85x too high), Constellation 82.17 (CAD read as USD).
-- Since muffin-ingest#104 (2026-10-10) every bar carries the currency Yahoo states for its own
-- line, so the view reads that label.
--
-- A BAR WITH NO LABEL GETS NO PRICE RATIO. Its quote currency is null, so neither `same_currency`
-- nor `convertible` holds and `fx` is null: a gap, rather than a point a hundred times out.
-- Ratios that do not touch the price (margins, ROE, ROA) are unchanged.
--
-- WHY NOW (umbrella docs/deferred/2026-10-10-the-ratio-view-reads-the-bar-s-label.md). The switch
-- waited for the chart lane's first rotation: until a security's first chart visit its bars kept
-- the old guess, and for Tel Aviv and Johannesburg that guess was the wrong unit. Measured
-- 2026-10-16: every one of the 11,542 securities with a bar in the last week has a chart
-- partition, and `labels_changed` ran 374, 205, 121, 367, 228 over the first five nights and 0 on
-- the sixth, the first night of the second rotation.
--
-- WHO IT MOVES, measured 2026-10-16 over the 12,006 securities with a bar in the last 14 days
-- (newest bar's label against `security.currency_code`): 11,109 unchanged, 493 change currency,
-- 150 gain one and 248 lose it. The largest changes: Hong Kong lines labelled CNY (129) or USD (68),
-- US lines of Chinese companies labelled CNY (42), Canadian, Singapore, Norwegian, Australian, euro
-- and Mexican lines labelled USD (~115), and subunit lines labelled in their major unit (KWF 28,
-- ILA 42, ZAC 8). The gains are Thai (72), Korean (53) and Turkish (20) lines with no currency at
-- all. Of the 248 that lose it, 238 are London lines whose pence stay unlabelled until `GBX`
-- (migration 20261010160000) is in `market.currency` and each line's next chart visit relabels
-- it; the rest are 7 in Lima, 1 in Bangkok and 8 US OTC lines. Ten large London lines checked
-- serve no price ratio today (no TTM, and half-year balance sheets are read only from migration 20261010213000). Under
-- the old rule they would appear a hundred times out once that migration deploys, pence divided by
-- pounds. Under this one they stay gaps until the relabel, then are right.
--
-- `create or replace` keeps every grant: the columns and their types are unchanged.

create or replace view market.security_ratio_series as
WITH spans AS (
         SELECT m.security_id,
            m.metric_code,
            m.value,
            m.currency_code,
            m.as_of,
            m.period_type,
            lead(m.as_of) OVER (PARTITION BY m.security_id, m.metric_code ORDER BY m.as_of) AS next_as_of
           FROM market.security_metric m
             JOIN market.metric mt ON mt.code = m.metric_code
          WHERE (mt.is_flow AND (m.period_type = 'ttm'::text OR m.period_type = 'annual'::text AND NOT (EXISTS ( SELECT 1
                   FROM market.security_metric t
                  WHERE t.security_id = m.security_id AND t.metric_code = m.metric_code AND t.period_type = 'ttm'::text))) OR NOT mt.is_flow AND (m.period_type = ANY (ARRAY['quarter'::text, 'half'::text]))) AND (m.metric_code = ANY (ARRAY['eps_diluted'::text, 'revenue'::text, 'total_equity'::text, 'free_cash_flow'::text, 'net_income'::text, 'shares_diluted'::text, 'total_assets'::text]))
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
            pb.currency_code AS quote_currency,
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
            w.currency_code AS quote_currency,
            s.reporting_currency
           FROM ( SELECT DISTINCT ON (ss.symbol, (date_trunc('week'::text, pb.trade_date::timestamp with time zone))) ss.symbol,
                    pb.security_id,
                    pb.trade_date AS date,
                    pb.close,
                    pb.currency_code
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
            max(sp.currency_code) AS metric_currency,
            max(
                CASE
                    WHEN sp.metric_code = 'eps_diluted'::text THEN sp.period_type
                    ELSE NULL::text
                END) AS eps_basis,
            max(
                CASE
                    WHEN sp.metric_code = 'revenue'::text THEN sp.period_type
                    ELSE NULL::text
                END) AS revenue_basis,
            max(
                CASE
                    WHEN sp.metric_code = 'net_income'::text THEN sp.period_type
                    ELSE NULL::text
                END) AS ni_basis
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
            COALESCE(j.metric_currency, j.reporting_currency) AS report_currency,
            j.eps_basis,
            j.revenue_basis,
            j.ni_basis
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
            r.eps_basis,
            r.revenue_basis,
            r.ni_basis,
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
            p.eps_basis,
            p.revenue_basis,
            p.ni_basis,
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
            WHEN revenue > 0::numeric AND revenue_basis = ni_basis THEN round(net_income / revenue * 100::numeric, 4)
            ELSE NULL::numeric
        END AS net_margin_pct,
        CASE
            WHEN equity > 0::numeric THEN round(net_income / equity * 100::numeric, 4)
            ELSE NULL::numeric
        END AS roe_pct,
        CASE
            WHEN assets > 0::numeric THEN round(net_income / assets * 100::numeric, 4)
            ELSE NULL::numeric
        END AS roa_pct,
    eps_basis
   FROM converted;
