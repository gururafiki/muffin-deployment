-- THE UNIVERSE SAMPLE RUNS FROM pg_cron, NOT THROUGH PostgREST.
--
-- WHY. Every hourly `observability-sample` run since 2026-09-26 22:04 reported
-- `universeError: "canceling statement due to statement timeout"` with `metrics: 0`, and recorded
-- `ok: true`. `market.sample_universe()` was called as one PostgREST RPC, and the PostgREST role
-- stops a statement at 8 s. Measured on production 2026-10-03, in a rolled-back transaction: 17.6 s
-- for 371 metrics. Its `max(trade_date)` over `market.price_bar` alone costs 2.3 s; that read arrived
-- with the 2026-09-26 price-reader fix, and the failures began the next hour.
--
-- What stopped with it, for a week:
--   * `scheduler.minutes_since_tick`, the only input of the alert "The scheduler has stopped
--     firing". With no sample, the rule's `coalesce(…, 9999)` reported 9999 continuously.
--   * every metric family `sample_universe` writes, twelve of them: `rows_estimate`, `bytes`,
--     `fresh_hours`, `missing`, `expiring`, `growth`, `identifiers`, `stale`, `tracked_funds`,
--     `segments`, `equities` and `scheduler`. Only `defect`, `dist` and `provenance` kept arriving,
--     because `sample_quality`, a separate RPC, writes them.
--
-- WHY pg_cron. A statement timeout cannot be escaped from inside the statement: PostgreSQL arms the
-- timer once, at statement start, so the function's own `set_config('statement_timeout', '30s')`
-- never applied. A pg_cron job runs as its owner, `postgres`, which has no statement timeout. The
-- job is still bounded: its command sets 60 s as a separate statement in the same query string,
-- which since PostgreSQL 13 applies to the next statement (measured on the node:
-- `set statement_timeout = '1s'; select pg_sleep(3)` is cancelled). A runaway sample cannot hold
-- locks a deploy needs for longer than that.
--
-- At :05, one minute after `muffin-observability` (:04), which still samples the backlogs and the
-- coverage through the edge function and no longer calls `sample_universe`.
--
-- Guarded on the relation: the migration tests run on plain Postgres with no pg_cron.
-- `cron.schedule` with an existing job name updates that job, so re-applying is safe.

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice '  --  no pg_cron here (the migration tests): nothing to schedule';
    return;
  end if;
  execute $q$
    select cron.schedule(
      'muffin-universe',
      '5 * * * *',
      $c$set statement_timeout = '60s'; select market.sample_universe()$c$)
  $q$;
end $$;
