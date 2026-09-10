-- ONE FISCAL PERIOD IS ONE POINT ON THE CHART.
--
-- AAPL's annual revenue was plotted TWICE for 2025 and twice for 2024:
--
--     2025-09-30  416.2B  yfinance      2024-09-30  391.0B  yfinance
--     2025-09-27  416.2B  sec-xbrl      2024-09-28  391.0B  sec-xbrl
--
-- Two sources, one fiscal year, period ends three days apart. The VALUES AGREE — all 18 duplicate
-- pairs measured on 2026-08-22 agree to within 0.1% — so nothing here is wrong, and that is exactly
-- why it survived: no floor, no count and no units check can see a number that is merely present
-- twice. It is visible only on the rendered page, as a doubled point.
--
-- ── WHY THE ORIGINAL PLAN CALLED THIS A GUARD ─────────────────────────────────────────────────
--
-- The plan that introduced the quarterly repair noticed this and sized it at "0 of 252 securities
-- sampled", concluding it deserved a check rather than a migration. Re-measured against production:
-- **5 of 142 securities (3.5%)**, AAPL among them. A guard alone would therefore have failed CI on
-- the day it was written, against data that is not wrong — which is how a guard gets deleted.
--
-- ── THE COLLAPSE ──────────────────────────────────────────────────────────────────────────────
--
-- Rows for one (security, metric, period_type) whose period ends fall within SEVEN DAYS of each
-- other are one fiscal period. Seven is safe by a wide margin: quarters are ~90 days apart and
-- annual periods ~365, so no two genuine periods can collide, while a fiscal-year end reported as
-- both "the Saturday nearest 30 September" and "30 September" always does.
--
-- The survivor is the HIGHEST-PRIORITY SOURCE, the same `order by ds.priority desc` this schema
-- already uses to choose between a filing and a provider. That is not merely a tie-break here: it
-- also picks the more accurate DATE. `sec-xbrl` (275) reports the true fiscal period end,
-- 2025-09-27; `yfinance` (100) rounds it to the month end. The label follows the filing.
--
-- Window functions cannot be nested, so the cluster id is built in two steps: `lag` marks where a
-- gap exceeds seven days, then a running `sum` of those marks numbers the clusters.

drop view if exists market.security_metric_series;

create view market.security_metric_series as
with gapped as (
  select
    sm.security_id,
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
             partition by sm.security_id, sm.metric_code, sm.period_type order by sm.as_of
           ) <= 7 then 0
      else 1
    end as starts_cluster
  from market.security_metric sm
  join market.data_source ds on ds.code = sm.source_code
),
clustered as (
  select
    g.*,
    sum(g.starts_cluster) over (
      partition by g.security_id, g.metric_code, g.period_type order by g.as_of
    ) as period_group
  from gapped g
)
select distinct on (c.security_id, c.metric_code, c.period_type, c.period_group)
  sym.symbol,
  c.security_id,
  c.metric_code,
  m.name    as metric_name,
  m.category,
  m.unit,
  m.is_derived,
  c.period_type,
  c.as_of,
  c.value,
  c.currency_code,
  c.source_code
from clustered c
join market.metric m            on m.code = c.metric_code
join market.security_symbol sym on sym.security_id = c.security_id
order by c.security_id, c.metric_code, c.period_type, c.period_group,
         -- The filing wins over the provider, and with it the true fiscal period end.
         c.priority desc, c.as_of desc;

comment on view market.security_metric_series is
  'Metric series with the symbol. ONE ROW PER FISCAL PERIOD: rows for the same (security, metric, period_type) whose period ends fall within seven days are one period reported by two sources, and the highest-priority source wins — which also picks the true fiscal period end (sec-xbrl 2025-09-27) over the provider''s rounded month end (yfinance 2025-09-30). Without it a chart plots one fiscal year twice, with values that agree, which no count or floor can detect.';

grant select on market.security_metric_series to anon, authenticated, service_role;

notify pgrst, 'reload schema';
