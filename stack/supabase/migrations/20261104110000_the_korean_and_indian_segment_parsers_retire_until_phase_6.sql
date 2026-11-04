-- THE KOREAN AND INDIAN SEGMENT PARSERS RETIRE UNTIL PHASE 6 (decided by the user 2026-11-04).
--
-- `security-kr-segments` and `security-in-segments` have failed every run since 2026-11-01 13:24
-- and 14:32 UTC with `pending_kr_segments read failed: canceling statement due to statement
-- timeout` (and the same for `pending_in_segments`), 66-72 failed runs every six hours. Both
-- queues are EMPTY: measured 2026-11-02 as `postgres`, 0 rows in 19.5 s and 13.7 s against the
-- PostgREST role's 8 s. Phase 5's CIK grid took `security_filing` from ~250,000 rows to 1,226,499,
-- the planner's estimate for the 6,518 DART filings fell to 15, and it joined fund holdings by
-- nested loop (260 M rows filtered). The views did not change; the table's growth moved the plan.
-- They kept `muffin-resource-stalled` firing and market-verify red from 11-02.
--
-- Per the user's rule the edge is not fixed; segments move to Dagster in Phase 6
-- (umbrella docs/deferred/2026-11-02-the-segment-queues-time-out-on-the-grid-s-filings.md,
-- docs/deferred/2026-11-02-the-segment-queue-reads-the-regulator.md). New Korean and Indian filings
-- keep arriving through `kr-filings` and `in-filings` and wait for that lane. The SEC parser
-- (`security-segments`) keeps running, and `security-cn-segments` is unaffected.
--
-- RETIRES: security-kr-segments, security-in-segments
--
-- Both names are in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate. Their
-- rotation rows were already disabled when they moved to their own jobs; the jobs are removed here.
-- The queue views STAY: three behaviour tests hold their rules (a Korean filing is not a SEC one,
-- a PDF reaches only the parser that reads it, a queue reaches every company), which Phase 6's lane
-- inherits, and the backlog sampler already falls back to the planner's estimate when their count
-- times out. They leave with the handlers at Phase 6's contract.

update market.cron_resource set enabled = false
 where resource in ('security-kr-segments', 'security-in-segments');

do $$
begin
  -- Guarded on the table, not with an exception handler: the migration tests run on plain
  -- Postgres with no pg_cron, where even planning a query that names `cron.job` fails.
  if to_regclass('cron.job') is not null then
    execute $q$select cron.unschedule(jobname) from cron.job
                where jobname in ('muffin-kr-segments', 'muffin-in-segments')$q$;
  end if;
end $$;
