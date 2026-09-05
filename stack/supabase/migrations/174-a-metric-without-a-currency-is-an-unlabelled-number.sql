-- A METRIC WITHOUT A CURRENCY RENDERS AS A BARE NUMBER, AND 990,847 OF THEM HAVE NONE.
--
-- Measured in production 2026-09-05. `security_metric.currency_code` is written straight from
-- `security_statement.currency`, and the yfinance income/balance/cash endpoints carry no currency
-- field at all — so every metric derived from them is NULL:
--
--   Korea     116 of 116 null      Germany  151 null / 80 EUR / 10 USD
--   Japan      55 null / 4 JPY     US        13 null / 474 USD / 13 ARS
--
-- The consequence is on the page: `money.ts` deliberately leaves a figure UNLABELLED rather than
-- guessing a currency — defaulting to dollars is how Alibaba's CNY revenue once rendered as
-- "$1.02T" — so a Korean or German stock page draws its income-statement Sankey and its statement
-- table as bare numbers, beside a segment breakdown that correctly says KRW.
--
-- THE FALLBACK ALREADY EXISTS AND THIS VIEW SIMPLY DID NOT USE IT. Migration 108 put the reporting
-- currency on `security.reporting_currency` and 109 taught `security_ratio_series` to
-- `coalesce(metric_currency, reporting_currency)` — which is why P/E works for Samsung while the
-- metric it is computed from has no currency. This is the same expression, one view over.
--
-- IT MUST BE THE REPORTING CURRENCY, NOT `security.currency_code`, and that was settled by probing
-- the securities expected to DISAGREE rather than the ones expected to match:
--
--   BHP.AX     quote AUD   reports USD      <- differ
--   SHEL.L     quote GBP   reports USD      <- differ
--   005930.KS  quote KRW   reports KRW      7203.T / NESN.SW / AAPL all agree
--
-- `security.currency_code` is a MIXTURE — N-PORT's `curCd` (the quote currency) first, the
-- fundamentals response second — so using it would relabel Shell's USD accounts as pounds for the
-- two companies where it matters, while looking perfectly right for everyone else.
--
-- A FALLBACK, NEVER AN OVERRIDE: a metric that states its own currency states it from the filing,
-- and SEC-sourced rows do. Only the nulls change.
--
-- WHY THE VIEW AND NOT THE DERIVATION. Filling the column would need a backfill over 990,847 rows
-- and would bake today's answer in: `reporting_currency` is refreshed by the fundamentals resource,
-- and a stored copy cannot follow it. One expression in the serving layer is also what stops the
-- next caller re-deriving it wrongly — the same reasoning that put the currency-withholding rule
-- inside `security_statement_current` rather than in its callers.
--
-- Copied from migration 126, which is this view's CURRENT definer — `create or replace view` means
-- the last file wins outright, so the definition must be the latest one and not the one that
-- introduced it.

\set ON_ERROR_STOP on

drop view if exists market.security_metric_series;

create view market.security_metric_series as
with gapped as (
  select
    sm.security_id,
    -- THE SYMBOL IS RESOLVED HERE, NOT AT THE TOP, AND IT IS IN THE PARTITION BY BELOW.
    -- PostgreSQL pushes a predicate below a window aggregate only when it references a
    -- PARTITION BY column. Joined at the top instead, `symbol = 'AAPL'` could not push down, so
    -- the windows and the DISTINCT ON ran over the WHOLE table first: measured on the deployed
    -- view, `Rows Removed by Filter: 1,260,808` to return 446 rows, 4,300 ms, over the 3 s anon
    -- ceiling. `symbol_security` is UNIQUE on security_id, so adding it to the partition key
    -- cannot change a single partition — it only makes the filter pushable.
    -- Measured after: 1,277,638 rows scanned -> 521, and 4,300 ms -> 3.4 ms.
    sym.symbol,
    sm.metric_code,
    sm.period_type,
    sm.as_of,
    sm.value,
    sm.currency_code,
    sm.source_code,
    ds.priority,
    -- A NULL `lag` is the first row of its partition: `null <= 7` is NULL, the CASE falls through
    -- to 1, and the cluster numbering starts at 1. Exactly the behaviour wanted, and the reason
    -- this is not written as a negation.
    case
      when sm.as_of - lag(sm.as_of) over (
             partition by sym.symbol, sm.security_id, sm.metric_code, sm.period_type order by sm.as_of
           ) <= 7 then 0
      else 1
    end as starts_cluster
  from market.security_metric sm
  join market.data_source ds on ds.code = sm.source_code
  join market.symbol_security sym on sym.security_id = sm.security_id
),
clustered as (
  select
    g.*,
    sum(g.starts_cluster) over (
      partition by g.symbol, g.security_id, g.metric_code, g.period_type order by g.as_of
    ) as period_group
  from gapped g
)
select distinct on (c.security_id, c.metric_code, c.period_type, c.period_group)
  c.symbol,
  c.security_id,
  c.metric_code,
  m.name    as metric_name,
  m.category,
  m.unit,
  m.is_derived,
  c.period_type,
  c.as_of,
  c.value,
  -- THE EFFECTIVE REPORTING CURRENCY. The filing's own answer wins; the company's reporting
  -- currency fills in where the provider sent none. Never `s.currency_code`, which is the QUOTE
  -- currency for a security whose venue differs from where it reports.
  coalesce(c.currency_code, s.reporting_currency) as currency_code,
  c.source_code
from clustered c
join market.metric m             on m.code = c.metric_code
join market.security s           on s.security_id = c.security_id
order by c.security_id, c.metric_code, c.period_type, c.period_group,
         -- The filing wins over the provider, and with it the true fiscal period end.
         c.priority desc, c.as_of desc;

comment on view market.security_metric_series is
  'One point per fiscal period per metric, the filing preferred over the provider. `currency_code` is EFFECTIVE — the metric''s own currency where the source stated one, else the company''s `reporting_currency` — because the yfinance statement endpoints carry no currency field and 990,847 metrics were therefore null, which `money.ts` correctly renders as an unlabelled number. It is the REPORTING currency and never `security.currency_code`: BHP quotes AUD and reports USD, Shell quotes GBP and reports USD. Joins the MATERIALISED `symbol_security`, not `security_symbol`: the latter is a per-security lateral, so filtering by symbol walked the whole universe and timed out for anon.';

grant select on market.security_metric_series to anon, authenticated, service_role;

notify pgrst, 'reload schema';
