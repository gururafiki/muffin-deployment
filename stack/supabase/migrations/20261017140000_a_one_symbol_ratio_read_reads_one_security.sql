-- A ONE-SYMBOL RATIO READ COMPUTES ONE SECURITY'S SPANS, NOT EVERY SECURITY'S.
--
-- WHY. The stock page reads `security_ratio_series` for one symbol, and every P/E chart timed out
-- for users (`57014`, anon's 3 s ceiling) from the 2026-10-16 deploy. Measured on production
-- 2026-10-17, AAPL daily took 6.4 s warm and 15 s cold.
--   * THE CAUSE: `spans` applies `lead()` over ALL of `security_metric`. A filter on the symbol cannot
--     pass a window that does not partition by it, so the plan read 1.57 M rows of the seven ratio
--     metrics and sorted them to disk before a merge join narrowed them to one company's 271 bars.
--   * IT WAS ALREADY THERE. The shape is as old as the view. #428's fiscal-year fallback added an
--     anti-join probed 616,179 times, and the night's TTM re-derivation added ~250,000 rows, which
--     together took it past the ceiling.
--
-- THE FIX. `spans` joins `symbol_security` and partitions its window by the symbol as well, and
-- `joined` matches spans to bars on the symbol too. Postgres pushes a filter on a column every window
-- partitions by below the window, so the stock page's `symbol = …` now narrows the spans to one
-- company before `lead()` runs. `symbol_security` holds one row per security (its unique index on
-- `security_id`), so the windows are the same and so are the rows.
--   * MEASURED on production before shipping, against the live view in a rolled-back transaction:
--     12 symbols (pence, agorot, fils, half-year reporters, an ADR), 8,720 rows each way and 0
--     differences either way. AAPL daily 71 ms, AAPL weekly 153-346 ms, SAP.DE daily 111 ms.
--   * A LATERAL per security was tried first and rejected. It was right for daily, but a misestimate
--     of the weekly arm (200 rows expected, 2,393 actual) made the planner re-run the window once per
--     weekly bar: 4.6 s. A partition column leaves no such choice.
--
-- Same columns in the same order, so `create or replace` keeps the grants and the comment.
-- Guarded by tests/a-one-symbol-ratio-read-reads-one-security.sql, which counts the metric rows a
-- one-symbol read touches.

create or replace view market.security_ratio_series as
WITH spans AS (
         SELECT ss.symbol,
            m.security_id,
            m.metric_code,
            m.value,
            m.currency_code,
            m.as_of,
            m.period_type,
            lead(m.as_of) OVER (PARTITION BY ss.symbol, m.security_id, m.metric_code ORDER BY m.as_of) AS next_as_of
           FROM market.symbol_security ss
             JOIN market.security_metric m ON m.security_id = ss.security_id
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
             JOIN spans sp ON sp.symbol = b.symbol AND sp.security_id = b.security_id AND b.date >= sp.as_of AND (sp.next_as_of IS NULL OR b.date < sp.next_as_of)
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
