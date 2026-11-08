-- THE COVERAGE SAMPLE HAS ROOM, AND `insider_trade` STAYS VISIBLE TO ITS INDEX-ONLY SCANS.
-- Decided 2026-11-08 (the user), options 1 and 2 of umbrella
-- docs/deferred/2026-11-07-the-coverage-sample-reaches-its-120-second-bound.md.
--
-- WHY. `muffin-coverage` runs `set statement_timeout = '120s'; select market.sample_coverage()`
-- (20261003170000), and `sample_coverage` reads `market.coverage_current` whole. Its durations, from
-- `cron.job_run_details`: 50, 84, 43, 72, 71, 119 and 76 s from 11-04 17:23 to 11-07 17:23, then
-- **11-08 05:23 cancelled at 120 s**, so that half-day's coverage point is lost. On 10-03 the whole
-- sample took 8.6 s cold. The grid's tables grew through October (`security_filing` 1.21 M rows,
-- `security_metric` 7.9 M), and on 11-07 the insider history took `insider_trade` from 0.75 M to
-- 5.52 M rows.
--
-- The largest node in `coverage_current`'s plan is the index-only scan behind
-- `select distinct security_id from market.insider_trade`, with heap fetches: 33 s across three
-- workers on 11-07 14:35. 926,730 rows were inserted after the 14:21 autovacuum, so they have no
-- visibility-map bits, and an index-only scan reads the heap for each one. Autovacuum's insert
-- trigger is `1000 + 0.2 * reltuples`, about 1.1 M rows here, and the daily Form 4 lane adds about
-- 1,000-2,000, so on the defaults the next vacuum is months away.
--
-- WHAT.
--   1. `muffin-coverage` gets 300 s. The sample is observability: Grafana reads `coverage_sample`,
--      the app never does, so a longer statement costs only CPU at 05:23 and 17:23. The same bound
--      `muffin-segment-spine` has carried since 20261003190000.
--   2. `insider_trade` vacuums after 1% of its rows are new inserts (~55,000), not 20%. Insert-mostly
--      tables are what this setting is for, and it helps every index-only read of the table, not
--      only the sample. On the next autovacuum pass after this deploy, the 926,730 uncovered rows
--      are past the new threshold.
--
-- NOT DONE. Reading cheaper sources in `coverage_current` (option 3) waits for Phase 8; an alert on
-- the job's duration (option 4) waits to see whether the trend continues. The note stays open until
-- a week of runs finishes well under 300 s.
--
-- `alter table … set (…)` takes SHARE UPDATE EXCLUSIVE: it blocks neither reads nor writes.
-- `cron.schedule` with an existing name updates that job in place. Guarded on the relation: the
-- migration tests run on plain Postgres with no pg_cron.

alter table market.insider_trade set (autovacuum_vacuum_insert_scale_factor = 0.01);

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice '  --  no pg_cron here (the migration tests): nothing to schedule';
    return;
  end if;
  execute $q$
    select cron.schedule(
      'muffin-coverage',
      '23 5,17 * * *',
      $c$set statement_timeout = '300s'; select market.sample_coverage()$c$)
  $q$;
end $$;
