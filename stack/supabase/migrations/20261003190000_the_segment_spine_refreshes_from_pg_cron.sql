-- THE SEGMENT SPINE REFRESHES FROM pg_cron, AND RECORDS ITS OWN REFRESH.
--
-- WHY. `refresh_segment_spine()` was called by the `facets-refresh` edge resource as its own
-- PostgREST RPC, one statement under the role's 8 s ceiling. It last succeeded on 2026-09-23 at
-- 21:14, in 7,992 ms (7,748 ms five runs earlier), and has failed every run since: 148
-- `canceling statement due to statement timeout`, ten days, with `facets-refresh` recording ok
-- each time on purpose (the screener's spine had refreshed). Measured on production 2026-10-03:
-- 11,682 ms cold, 7,570 ms warm, 24,072 rows. Its cost tracks `security_segment` (1.44M rows),
-- which grows with every parsed filing, so no page or index brings it back under the ceiling.
--
-- So for ten days `security_segment_spine` was frozen at 09-23, and everything that reads it
-- whole read a snapshot: `derive_segment_classification` (Stage 5's Dagster asset ran on it),
-- the coverage segment facets and the Business lines dashboard. The app was not affected; it reads
-- the live view per security. `market-verify` was red on exactly this from 09-30, and nothing
-- alerts on a failing `market-verify`, only on one that does not run.
--
-- WHAT.
--   * `muffin-segment-spine` at :16 every hour, as `postgres`, bounded by a leading SET in the
--     same command. Measured on the node: that exact string, sent as one implicit transaction,
--     refreshes CONCURRENTLY and returns, 24,072 rows in 7,570 ms.
--   * The function RECORDS its own refresh, as `segment_spine.duration_ms` and
--     `segment_spine.rows` in `universe_sample` under one timestamp. A pg_cron job writes no
--     `refresh_run` row, and those report fields were the only record of the spine's health:
--     market-verify's check, the dashboard panel and the staleness alert all read the samples now.
--     A refresh that fails or times out rolls its own sample back, so a stale or absent sample is
--     the failure signal; `cron.job_run_details` holds the error text.
--   * `facets-refresh` no longer calls it.

create or replace function market.refresh_segment_spine()
 returns table(rows_refreshed bigint, duration_ms integer)
 language plpgsql
 security definer
 set search_path to 'market', 'pg_catalog'
 set max_parallel_workers_per_gather to '0'
 set max_parallel_maintenance_workers to '0'
as $function$
declare
  t0 timestamptz := clock_timestamp();
  t1 timestamptz;
  n  bigint;
  ms integer;
begin
  -- CONCURRENTLY so the refresh does not take an ACCESS EXCLUSIVE lock on the thing every
  -- aggregate reads. It needs the spine's unique index.
  refresh materialized view concurrently market.security_segment_spine;
  select count(*) into n from market.security_segment_spine;
  t1 := clock_timestamp();
  -- `extract(milliseconds from ...)` ALREADY INCLUDES THE SECONDS field, so adding
  -- `1000 * extract(seconds ...)` double-counts it: a measured 6,454 ms call reported 12,436.
  ms := (extract(epoch from t1 - t0) * 1000)::integer;
  -- ONE timestamp for both rows: `universe_sample` is keyed (sampled_at, metric), and two clock
  -- readings would file one refresh as two samples.
  insert into market.universe_sample (sampled_at, metric, value)
  values (t1, 'segment_spine.duration_ms', ms), (t1, 'segment_spine.rows', n)
  on conflict do nothing;
  return query select n, ms;
end;
$function$;

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
      'muffin-segment-spine',
      '16 * * * *',
      $c$set statement_timeout = '300s'; select market.refresh_segment_spine()$c$)
  $q$;
end $$;
