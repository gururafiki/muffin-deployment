-- `derive_security_metrics` COST THE SAME AT EVERY PAGE SIZE, WHICH IS THE TELL.
--
-- Measured against production 2026-08-21, one call at a time:
--
--     p_limit    25   ->  8.13s  canceling statement due to statement timeout
--     p_limit    50   ->  6.86s  ok
--     p_limit   100   ->  6.17s  ok
--     p_limit   200   ->  6.12s  ok
--
-- A page of 25 costing MORE than a page of 200 is not noise, it is proof the page is not what is
-- being paid for. The function selects `... order by st.as_of limit p_limit`, and
-- `market.security_statement` had no index on `as_of` — only the primary key
-- (security_id, statement, period_ending, period_type) and (security_id, statement). So every call
-- sorted all 107,000+ statements before the LIMIT could discard them: **a limit after a sort pays
-- for the whole sort**.
--
-- That put the statement at ~6s against the EIGHT SECOND timeout of the role PostgREST uses, so it
-- succeeded or failed depending on load — intermittently, in a way that reads as a provider problem.
-- It failed on the first real `security-quarters` run, and tuning the page (twice) could not have
-- fixed it because the page was never the cost.
--
-- The inner anti-join is already served: `security_metric_period_idx` is
-- (security_id, as_of, fetched_at DESC), which is exactly what the NOT EXISTS asks for. Only the
-- ordering was unindexed.

create index if not exists security_statement_as_of_idx
  on market.security_statement (as_of);

comment on index market.security_statement_as_of_idx is
  'Serves `derive_security_metrics`, which pages `order by as_of limit N`. Without it the LIMIT could not stop the scan early and every call sorted all 107k statements — ~6s against an 8s statement timeout, failing intermittently.';

notify pgrst, 'reload schema';
