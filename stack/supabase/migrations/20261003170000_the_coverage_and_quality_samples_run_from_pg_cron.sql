-- THE COVERAGE AND QUALITY SAMPLES RUN FROM pg_cron, NOT THROUGH PostgREST.
--
-- WHY. 20261003135000 moved `sample_universe` off the PostgREST role's 8 s statement ceiling and
-- said, in the edge handler, that the coverage and quality samples "each fit the ceiling". That was
-- not measured, and for coverage it is false. Measured on production 2026-10-03, rolled back:
--
--   * `sample_coverage()` 8,592 ms cold and 3,255 ms warm. It straddles the ceiling, so the
--     twice-daily RPC failed whenever the cache was cold: every hourly retry on 2026-09-28 (24 of
--     them) and every one from 10-03 01:04 to 09:04 recorded `coverage: 0`, while the run stayed
--     `ok: true`. The samples that did land on 10-03 came from the deploy's own end-of-run sample,
--     which runs as `postgres` with no timeout. Migration 140 recorded the same coin flip at
--     4.9-8.7 s cold and contained it with columns; the view has grown back to the edge.
--   * `sample_quality()` 4,380 ms, 55% of the ceiling. It is not failing; it is next. A sample that
--     grows with the data does not belong under a fixed RPC ceiling, so it moves now rather than
--     the week it starts failing.
--
-- WHAT. Two pg_cron jobs, as `postgres`, each bounding its own statement with a leading SET in the
-- same command (measured on the node: `set statement_timeout = '1s'; select pg_sleep(3)` is
-- cancelled), so a runaway sample cannot hold locks a deploy needs:
--
--   * `muffin-quality`   at :06 every hour, as before (it was taken at :04 by the edge handler);
--   * `muffin-coverage`  at 05:23 and 17:23 UTC, twice a day, as before. The edge handler gated it
--     on "11 hours since the last sample" because GitHub's schedules drifted; pg_cron does not.
--
-- The edge handler `observability-sample` keeps the backlog samples (one RPC per backlog, with a
-- planner-estimate fallback, written by the caller so a timeout cannot take its own error row
-- with it) and the prune. It no longer calls either function.
--
-- WATCHED. A pg_cron job writes no `refresh_run` row, so the stalled-resource alert cannot see it
-- stop. The rule "An observability sample has stopped arriving" (rules.yml) reads the samples'
-- own age; the universe sample is already watched by "The scheduler has stopped firing".
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
      'muffin-quality',
      '6 * * * *',
      $c$set statement_timeout = '60s'; select market.sample_quality()$c$)
  $q$;
  execute $q$
    select cron.schedule(
      'muffin-coverage',
      '23 5,17 * * *',
      $c$set statement_timeout = '120s'; select market.sample_coverage()$c$)
  $q$;
end $$;
