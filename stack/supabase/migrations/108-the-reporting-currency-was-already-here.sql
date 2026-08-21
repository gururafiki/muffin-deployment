-- A COMPANY'S REPORTING CURRENCY WAS ALREADY FETCHED AND STORED, AND NOTHING READ IT.
--
-- Making quarterly statements work outside the US (migration 106) produced quarters, metrics and
-- TTM for foreign filers — and no P/E, because `security_ratio_series` withholds every price-based
-- ratio unless it knows both currencies. The income/balance/cash endpoints carry NO currency field
-- (`reported_currency` was a wrong guess recorded in CLAUDE.md), so every yfinance-derived metric
-- has `currency_code` null and the gate correctly declined to divide. Samsung showed a net margin
-- of 21.46% beside an empty P/E.
--
-- `equity/fundamental/metrics` carries it, `security-fundamentals` already fetches that response,
-- and it has been sitting in `security_fundamentals.raw->>'currency'` all along. Fifth instance of
-- "the answer is already in a response you fetch" — after market cap on `equity/profile`, the
-- operating country on the same call, and a second market cap in this very jsonb.
--
-- ── IT IS THE REPORTING CURRENCY, NOT THE QUOTE CURRENCY, AND THAT WAS MEASURED ──────────────────
--
-- The whole value depends on which of the two it is, so it was probed with the securities expected
-- to DISAGREE rather than the easy ones:
--
--     BHP.AX     quotes AUD  ->  currency USD
--     SHEL.L     quotes GBP  ->  currency USD
--     005930.KS  quotes KRW  ->  currency KRW
--     7203.T     quotes JPY  ->  currency JPY
--
-- BHP and Shell are foreign issuers that genuinely report in dollars. Had this been the quote
-- currency both would have answered AUD and GBP, and using it would have made every ratio pass a
-- gate that exists precisely to stop dividing dollars by kroner.

alter table market.security add column if not exists reporting_currency text;

comment on column market.security.reporting_currency is
  'The currency the company reports its accounts in — NOT the currency its listing trades in. BHP and Shell quote AUD and GBP and report USD. Promoted from security_fundamentals.raw->>''currency'' (yfinance), which is measured to be the reporting currency.';

-- PROMOTED, NOT JOINED AT READ TIME. `security_ratio_series` is the largest join the app sends and
-- has a 2,000ms anon budget; three separate views in this schema have already been broken by an
-- extra join changing the plan. A column costs nothing to read.
--
-- Gated on the jsonb TYPE and the shape. A numeric-looking string casts cleanly and writes a wrong
-- value silently; anything not three letters is not a currency code, and migrations apply
-- `--single-transaction`, so one bad row would abort the whole deploy.
update market.security s
   set reporting_currency = upper(f.raw->>'currency')
  from market.security_fundamentals f
 where f.security_id = s.security_id
   and jsonb_typeof(f.raw->'currency') = 'string'
   and upper(f.raw->>'currency') ~ '^[A-Z]{3}$'
   and s.reporting_currency is distinct from upper(f.raw->>'currency');

-- ── AND THE VIEW USES IT AS A FALLBACK, NEVER AS AN OVERRIDE ────────────────────────────────────
--
-- A metric that states its own currency states it from the FILING (SEC XBRL puts the facts under a
-- currency unit key), which is the better source. The promoted column only fills the silence.
drop view if exists market.security_ratio_series;

create view market.security_ratio_series as
with
spans as (
  select
    m.security_id,
    m.metric_code,
    m.value,
    m.currency_code,
    m.as_of,
    lead(m.as_of) over (partition by m.security_id, m.metric_code order by m.as_of) as next_as_of
  from market.security_metric m
  join market.metric mt on mt.code = m.metric_code
  where m.period_type = case when mt.is_flow then 'ttm' else 'quarter' end
    and m.metric_code in ('eps_diluted', 'revenue', 'total_equity', 'free_cash_flow',
                          'net_income', 'shares_diluted', 'total_assets')
),
bars as (
  select ss.symbol, sp.security_id, sp.date, sp.close, sp.grain,
         s.currency_code as quote_currency,
         s.reporting_currency
  from market.security_price sp
  join market.symbol_security ss on ss.security_id = sp.security_id
  join market.security s on s.security_id = sp.security_id
),
joined as (
  select
    b.symbol, b.security_id, b.date, b.close, b.grain, b.quote_currency, b.reporting_currency,
    max(case when sp.metric_code = 'eps_diluted'    then sp.value end) as eps,
    max(case when sp.metric_code = 'revenue'        then sp.value end) as revenue,
    max(case when sp.metric_code = 'total_equity'   then sp.value end) as equity,
    max(case when sp.metric_code = 'free_cash_flow' then sp.value end) as fcf,
    max(case when sp.metric_code = 'net_income'     then sp.value end) as net_income,
    max(case when sp.metric_code = 'shares_diluted' then sp.value end) as shares,
    max(case when sp.metric_code = 'total_assets'   then sp.value end) as assets,
    max(sp.currency_code) as metric_currency
  from bars b
  join spans sp
    on sp.security_id = b.security_id
   and b.date >= sp.as_of
   and (sp.next_as_of is null or b.date < sp.next_as_of)
  group by b.symbol, b.security_id, b.date, b.close, b.grain, b.quote_currency, b.reporting_currency
),
resolved as (
  -- THE FILING FIRST, the company's stated reporting currency second, nothing third.
  select j.*, coalesce(j.metric_currency, j.reporting_currency) as report_currency
  from joined j
)
select
  symbol,
  security_id,
  date,
  grain,
  close,
  report_currency,
  quote_currency,
  case when report_currency is not null and report_currency = quote_currency then true else false end
    as currency_comparable,
  case when report_currency = quote_currency and eps > 0
       then round(close / eps, 4) end as pe_ratio,
  case when report_currency = quote_currency and revenue > 0 and shares > 0
       then round(close / (revenue / shares), 4) end as ps_ratio,
  case when report_currency = quote_currency and equity > 0 and shares > 0
       then round(close / (equity / shares), 4) end as pb_ratio,
  case when report_currency = quote_currency and fcf > 0 and shares > 0
       then round(close / (fcf / shares), 4) end as price_to_fcf,
  case when report_currency = quote_currency and eps > 0
       then round(eps / close * 100, 4) end as earnings_yield_pct,
  case when report_currency = quote_currency and fcf > 0 and shares > 0
       then round((fcf / shares) / close * 100, 4) end as fcf_yield_pct,
  -- Margins and returns need no price and therefore no currency agreement at all.
  case when revenue > 0 then round(net_income / revenue * 100, 4) end as net_margin_pct,
  case when equity > 0  then round(net_income / equity  * 100, 4) end as roe_pct,
  case when assets > 0  then round(net_income / assets  * 100, 4) end as roa_pct
from resolved;

comment on view market.security_ratio_series is
  'Ratios computed PER PRICE BAR from stored inputs, the way financecharts does it. A metric is stepwise in time, so each governs the bars in [as_of, next as_of). A ratio is NULL where the reporting and quote currencies differ (an ADR divides dollars by kroner and looks ordinary) or the denominator is not positive. The reporting currency comes from the FILING first and the company''s stated reporting currency (security.reporting_currency) second.';

grant select on market.security_ratio_series to anon, authenticated, service_role;

notify pgrst, 'reload schema';
