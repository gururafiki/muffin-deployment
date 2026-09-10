do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_ratio_series';
  if k = 'm' then execute 'drop materialized view if exists market.security_ratio_series cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_ratio_series cascade';
  end if;
end $$;
create view market.security_ratio_series as
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
            sp.security_id,
            sp.date,
            sp.close,
            sp.grain,
            s.currency_code AS quote_currency,
            s.reporting_currency
           FROM market.security_price sp
             JOIN market.symbol_security ss ON ss.security_id = sp.security_id
             JOIN market.security s ON s.security_id = sp.security_id
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
