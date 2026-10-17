-- A PRICE BAR IS SERVED WITH ITS CURRENCY, SO THE CHART NAMES THE UNIT OF THE BARS IT DRAWS.
--
-- WHY. The stock page's chart title names a currency (muffin-ui#137). Read from
-- `security_current.quote_currency`, it took that column's fallback: the listing's and the
-- security's legacy currency, which the edge filled with the REPORTING currency, wherever the price
-- lane had not yet recorded a bar's label. Rendered against live data on 2026-10-17, VOD.L read
-- `(EUR)` over pence, Lenovo `(USD)` over Hong Kong dollars, and TSM `(TWD)` over the ADR's
-- dollars, because `instrument_current` reads the linked company's home-market security. Over the
-- 12,013 securities with a recent bar, 796 titles would have contradicted the bars' own label and
-- 223 would have shown a guess over an unlabelled bar.
--
-- DECIDED 2026-10-17 (Phase 4 decision 20): the chart names the currency of the bars it draws.
-- Each row carries its bar's `currency_code`, the label Yahoo states for that line since
-- muffin-ingest#104. A bar with no label serves null, so the title goes unlabelled rather than
-- guessed: the same rule `security_ratio_series` follows since migration 20261016180000.
--
-- The column is appended, so `create or replace` keeps the grants. Each arm takes it from the
-- bar it serves: the daily arm row by row, the weekly arm from the week's newest bar, which is
-- the bar whose close it serves. Guarded by tests/a-price-bar-is-served-with-its-currency.sql.

create or replace view market.price_series as
SELECT ss.symbol,
    pb.trade_date AS date,
    pb.close,
    'daily'::text AS grain,
    pb.currency_code
   FROM market.price_bar pb
     JOIN market.symbol_security ss ON ss.security_id = pb.security_id
  WHERE pb.trade_date > (CURRENT_DATE - 400)
UNION ALL
 SELECT w.symbol,
    w.date,
    w.close,
    'weekly'::text AS grain,
    w.currency_code
   FROM ( SELECT DISTINCT ON (ss.symbol, (date_trunc('week'::text, pb.trade_date::timestamp with time zone))) ss.symbol,
            pb.trade_date AS date,
            pb.close,
            pb.currency_code
           FROM market.price_bar pb
             JOIN market.symbol_security ss ON ss.security_id = pb.security_id
          ORDER BY ss.symbol, (date_trunc('week'::text, pb.trade_date::timestamp with time zone)), pb.trade_date DESC) w;
