-- A RATIO IS COMPUTED PER BAR, NOT STORED.
--
-- financecharts' P/E page shows its hand: the table under the chart is `DATE | DILUTED EPS TTM |
-- ADJ close` with DAILY rows, and the zoom offers 1M through 20Y. They store the two INPUTS and
-- divide. Storing P/E instead would mean a row per security per day per ratio — ~12,350 x 5,000 x
-- 12 — to hold numbers that are a division of data already present, and every one of them would go
-- stale the moment a restatement landed.
--
-- ── A METRIC IS STEPWISE IN TIME ────────────────────────────────────────────────────────────
--
-- EPS TTM does not change daily: it holds its value from the day it is reported until the next
-- report, then steps. So each metric row is joined to the price bars in the RANGE it governs —
-- `[as_of, next as_of)` — rather than looked up per bar. That is one range join instead of a
-- lateral per bar, and it is also the correct SHAPE: a P/E that moved between reports because of
-- interpolation would be a fabrication.
--
-- ── AND THE TWO SIDES MUST BE IN THE SAME CURRENCY ──────────────────────────────────────────
--
-- `security_metric.currency_code` is the REPORTING currency (from the filing) and
-- `security.currency_code` is the QUOTE currency of the listing. For a domestic company they
-- agree. For an ADR they do not: Novo Nordisk reports in DKK and its US line trades in USD, so
-- `close / eps` divides dollars by kroner and produces a P/E that is wrong by the exchange rate
-- and looks entirely ordinary. That is the Alibaba shape — a plausible number in the right
-- magnitude — so the ratio is WITHHELD rather than guessed. Converting would need an FX rate at
-- each bar's date, which is a different feature.
--
-- ── NEGATIVE AND ZERO DENOMINATORS ──────────────────────────────────────────────────────────
--
-- A loss-making company has negative EPS. A "P/E of -14" is not a valuation, it is a division, and
-- charting it draws a mirror image of the price. Null, like every other convention here: no number
-- rather than a misleading one.

drop view if exists market.security_ratio_series;

create view market.security_ratio_series as
with
-- Each metric row governs the bars from its own date until the next one for that metric.
--
-- WHICH PERIOD, AND WHY IT IS NOT A CHOICE. A FLOW (revenue, earnings, cash flow) is only
-- comparable to a price over twelve months, so it takes `ttm`. A STOCK (equity, assets, share
-- count) is a balance at an instant and has no TTM at all, so it takes the latest `quarter`.
-- `metric.is_flow` already says which is which — the same column `derive_ttm` sums on — so this is
-- a join rather than a list that could drift from it.
--
-- Selecting BOTH period types for one metric would not error: it would put a quarterly EPS and a
-- TTM EPS in the same partition, so `lead()` would cut each other's spans into fragments and the
-- `max()` below would silently take whichever number is bigger. A P/E four times too low, on a
-- chart, with nothing to indicate it.
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
  select ss.symbol, sp.security_id, sp.date, sp.close, sp.grain, s.currency_code as quote_currency
  from market.security_price sp
  join market.symbol_security ss on ss.security_id = sp.security_id
  join market.security s on s.security_id = sp.security_id
),
joined as (
  select
    b.symbol, b.security_id, b.date, b.close, b.grain, b.quote_currency,
    max(case when sp.metric_code = 'eps_diluted'    then sp.value end) as eps,
    max(case when sp.metric_code = 'revenue'        then sp.value end) as revenue,
    max(case when sp.metric_code = 'total_equity'   then sp.value end) as equity,
    max(case when sp.metric_code = 'free_cash_flow' then sp.value end) as fcf,
    max(case when sp.metric_code = 'net_income'     then sp.value end) as net_income,
    max(case when sp.metric_code = 'shares_diluted' then sp.value end) as shares,
    max(case when sp.metric_code = 'total_assets'   then sp.value end) as assets,
    -- One currency for the lot: they come from the same filing, so any of them names it.
    max(sp.currency_code) as report_currency
  from bars b
  join spans sp
    on sp.security_id = b.security_id
   and b.date >= sp.as_of
   and (sp.next_as_of is null or b.date < sp.next_as_of)
  group by b.symbol, b.security_id, b.date, b.close, b.grain, b.quote_currency
)
select
  symbol,
  security_id,
  date,
  grain,
  close,
  report_currency,
  quote_currency,
  -- COMPARABLE ONLY WHEN BOTH SIDES ARE IN ONE CURRENCY. A null report currency (every yfinance
  -- period — that provider never says) is treated as unusable rather than as "probably the same".
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
  -- Margins and returns need no price and therefore no currency agreement at all: numerator and
  -- denominator are both from the filing.
  case when revenue > 0 then round(net_income / revenue * 100, 4) end as net_margin_pct,
  case when equity > 0  then round(net_income / equity  * 100, 4) end as roe_pct,
  case when assets > 0  then round(net_income / assets  * 100, 4) end as roa_pct
from joined;

comment on view market.security_ratio_series is
  'Ratios computed PER PRICE BAR from stored inputs, the way financecharts does it — their P/E page exposes `ADJ close` and `DILUTED EPS TTM` and divides. A metric is stepwise in time, so each governs the bars in [as_of, next as_of) rather than being interpolated. A ratio is NULL where the reporting and quote currencies differ (an ADR divides dollars by kroner and looks ordinary) or the denominator is not positive (a "P/E of -14" is a division, not a valuation).';

grant select on market.security_ratio_series to anon, authenticated, service_role;

-- Serves the range join: for one security, the metric spans in date order.
create index if not exists security_metric_span_idx
  on market.security_metric (security_id, metric_code, as_of)
  where period_type in ('ttm', 'quarter');

notify pgrst, 'reload schema';
