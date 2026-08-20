-- ADDING A FILTER CHANGED THE PLAN, AND THE PLAN WAS THE FEATURE.
--
-- Migration 94 gave `price_series` a `grain` so the app could ask for one resolution. Measured in
-- production immediately afterwards, as ANON, exactly the query the chart makes:
--
--   symbol=eq.AAPL                    ->   696 ms
--   symbol=eq.AAPL & grain=eq.daily   ->   57014 canceling statement due to statement timeout
--
-- The chart was broken by the filter it was given. `EXPLAIN` says why: with `grain` fixed to a
-- constant it folds out of the `distinct on` sort key, the planner's row estimate changes, and it
-- flips from hash-joining `security_symbol` ONCE to a nested loop that evaluates the view's
-- lateral subqueries PER ROW —
--
--   Filter: (COALESCE((SubPlan 3), ps.symbol, i.value) = 'AAPL')
--   ->  Nested Loop Left Join (actual rows=3056435)
--
-- three million evaluations of a symbol lookup to answer a query about one symbol.
--
-- ── THE FIX IS TO RESOLVE THE SYMBOL ONCE, NOT TO TUNE THE PLAN ─────────────────────────────
--
-- `with sym as materialized` makes Postgres evaluate the symbol resolution a single time and join
-- the result, which is what the fast plan was doing by luck. Measured on the same node: the nested
-- loop drops from 3,056,435 rows to 27,629 (the security count) and the query goes from a timeout
-- to **258 ms**; as `anon` under its real 3-second ceiling, AAPL returns 282 daily bars and SAP.DE
-- 276. Row-identical to the old view for the same symbol (282 = 282).
--
-- Reordering the `distinct on` was tried first and changed nothing — both orderings produced the
-- same per-row subplan, so the sort key was not the cause. Worth recording, because "the filter
-- changed the sort key" is the obvious story and it is wrong.
--
-- THIS IS THE THIRD TIME A VIEW HAS BEEN FAST UNTIL A SECOND PREDICATE ARRIVED (after
-- `fund_sector_weight` and `security_facets`), and the pattern is the same each time: a
-- per-row subquery inside a view, invisible until the planner stops hiding it. Time a view as
-- ANON, and time it with the CONJUNCTION the app actually sends.

drop view if exists market.price_series;

create view market.price_series as
-- MATERIALIZED, deliberately. Without the keyword Postgres is free to inline this and go back to
-- evaluating `security_symbol`'s laterals once per price row.
with sym as materialized (
  select security_id, symbol from market.security_symbol where symbol is not null
)
select distinct on (symbol, grain, date) symbol, date, close, grain
from (
  select s.symbol, sp.date, sp.close, sp.grain, 1 as priority
  from market.security_price sp
  join sym s on s.security_id = sp.security_id
  union all
  select p.symbol, p.date, p.close, 'daily'::text as grain, 2 as priority
  from market.prices p
) x
order by symbol, grain, date, priority;

comment on view market.price_series is
  'Every close the app can chart, by symbol and GRAIN: the security series first, the curated instrument series second. The symbol resolution is a MATERIALIZED cte because inlining it makes the planner evaluate security_symbol''s laterals once per price row — 3,056,435 times to answer a question about one symbol, which timed out for anon. A reader must filter on `grain` (the two overlap by design) and page (a 20-year weekly series is 1,077 rows, above PGRST_DB_MAX_ROWS).';

grant select on market.price_series to anon, authenticated, service_role;

notify pgrst, 'reload schema';
