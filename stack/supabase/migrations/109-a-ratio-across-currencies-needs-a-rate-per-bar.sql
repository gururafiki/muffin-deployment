-- BHP AND SHELL REPORT IN DOLLARS AND TRADE IN AUD AND GBP, SO THEY HAD NO RATIOS AT ALL.
--
-- Withholding was the right FIRST answer — dividing a GBP price by USD earnings gives a number
-- wrong by the exchange rate that looks entirely ordinary, which is the Alibaba shape. But it is
-- not the right LAST answer: the conversion is arithmetic and the rates are free. Measured
-- 2026-08-21, SHEL.L and BHP.AX returned `pe_ratio: null` with `currency_comparable: false` while
-- both are ordinary large caps a user would expect to see a P/E for. Foreign issuers reporting in
-- USD are common — most UK and Australian miners and energy majors do it.
--
-- ── A RATE PER BAR, NOT A RATE ──────────────────────────────────────────────────────────────────
--
-- `market.fx_rate` held THREE DAYS (41 currencies x 3), which is enough to reprice a market cap
-- today and useless here: converting a 2021 bar with today's rate is wrong by every intervening
-- move and, again, looks ordinary. The `fx-rates` resource now backfills ten years of WEEKLY rates,
-- and this view joins each price bar to the most recent rate AT OR BEFORE it — the same stepwise
-- range join the metrics already use, for the same reason. A rate we did not observe is not a rate,
-- so nothing is interpolated; a daily bar between two weekly rates carries the earlier one forward.
--
-- ── AND IT CONVERTS THE METRIC, NOT THE PRICE ───────────────────────────────────────────────────
--
-- The price is what the user sees on the chart and in every other panel; re-denominating it here
-- would make this view disagree with `price_series` about what a share costs. So the FILING is
-- moved into the quote currency: value_in_quote = value * usd_per_unit(report) / usd_per_unit(quote).
--
-- `currency_comparable` keeps its meaning — the two currencies AGREE — and a new `fx_converted`
-- says the ratio was made comparable rather than born that way, because those are different facts
-- and a reader is entitled to know which one they are looking at.

drop view if exists market.security_ratio_series;

create view market.security_ratio_series as
with
spans as (
  select
    m.security_id, m.metric_code, m.value, m.currency_code, m.as_of,
    lead(m.as_of) over (partition by m.security_id, m.metric_code order by m.as_of) as next_as_of
  from market.security_metric m
  join market.metric mt on mt.code = m.metric_code
  where m.period_type = case when mt.is_flow then 'ttm' else 'quarter' end
    and m.metric_code in ('eps_diluted', 'revenue', 'total_equity', 'free_cash_flow',
                          'net_income', 'shares_diluted', 'total_assets')
),
-- Each observed rate governs the days from its own date until the next one for that currency.
fx as (
  select
    r.currency_code, r.usd_per_unit, r.as_of,
    lead(r.as_of) over (partition by r.currency_code order by r.as_of) as next_as_of
  from market.fx_rate r
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
  -- The FILING first, the company's stated reporting currency second, nothing third.
  select j.*, coalesce(j.metric_currency, j.reporting_currency) as report_currency
  from joined j
),
priced as (
  select
    r.*,
    -- USD 1:1 without a row, so a USD leg never depends on the table having quoted the dollar.
    case when r.report_currency = 'USD' then 1 else fr.usd_per_unit end as report_usd,
    case when r.quote_currency  = 'USD' then 1 else fq.usd_per_unit end as quote_usd
  from resolved r
  left join fx fr
    on fr.currency_code = r.report_currency
   and r.date >= fr.as_of and (fr.next_as_of is null or r.date < fr.next_as_of)
  left join fx fq
    on fq.currency_code = r.quote_currency
   and r.date >= fq.as_of and (fq.next_as_of is null or r.date < fq.next_as_of)
),
converted as (
  select
    p.*,
    p.report_currency is not null
      and p.quote_currency is not null
      and p.report_currency = p.quote_currency as same_currency,
    -- Convertible only when BOTH legs have a rate at this bar. A missing rate is not a rate of 1.
    p.report_currency is not null
      and p.quote_currency is not null
      and p.report_currency <> p.quote_currency
      and p.report_usd is not null and p.quote_usd is not null
      and p.quote_usd > 0 as convertible,
    case
      when p.report_currency = p.quote_currency then 1
      when p.report_usd is not null and p.quote_usd is not null and p.quote_usd > 0
        then p.report_usd / p.quote_usd
    end as fx
  from priced p
)
select
  symbol,
  security_id,
  date,
  grain,
  close,
  report_currency,
  quote_currency,
  (same_currency or convertible) as currency_comparable,
  -- MADE comparable, rather than born that way. Different facts, and the reader is entitled to
  -- know which they are looking at.
  convertible as fx_converted,
  case when fx is not null and eps * fx > 0
       then round(close / (eps * fx), 4) end as pe_ratio,
  case when fx is not null and revenue > 0 and shares > 0
       then round(close / (revenue * fx / shares), 4) end as ps_ratio,
  case when fx is not null and equity > 0 and shares > 0
       then round(close / (equity * fx / shares), 4) end as pb_ratio,
  case when fx is not null and fcf > 0 and shares > 0
       then round(close / (fcf * fx / shares), 4) end as price_to_fcf,
  case when fx is not null and eps * fx > 0
       then round(eps * fx / close * 100, 4) end as earnings_yield_pct,
  case when fx is not null and fcf > 0 and shares > 0
       then round((fcf * fx / shares) / close * 100, 4) end as fcf_yield_pct,
  -- Margins and returns are filing-over-filing: no price, no currency, no rate. They were already
  -- right for these companies and must not start depending on FX now.
  case when revenue > 0 then round(net_income / revenue * 100, 4) end as net_margin_pct,
  case when equity > 0  then round(net_income / equity  * 100, 4) end as roe_pct,
  case when assets > 0  then round(net_income / assets  * 100, 4) end as roa_pct
from converted;

comment on view market.security_ratio_series is
  'Ratios computed PER PRICE BAR from stored inputs. A metric is stepwise in time; so is an exchange rate, and both are carried forward rather than interpolated. Where the filing and the listing use different currencies the FILING is converted into the quote currency at the rate observed for that bar — `fx_converted` says so. A ratio is NULL where no rate is held for the bar or the denominator is not positive: a missing rate is not a rate of 1.';

grant select on market.security_ratio_series to anon, authenticated, service_role;

-- Serves the two stepwise FX joins.
create index if not exists fx_rate_currency_date_idx on market.fx_rate (currency_code, as_of);

notify pgrst, 'reload schema';
