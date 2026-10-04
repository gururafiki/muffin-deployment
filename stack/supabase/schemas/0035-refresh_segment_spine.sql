CREATE OR REPLACE FUNCTION market.refresh_segment_spine()
 RETURNS TABLE(rows_refreshed bigint, duration_ms integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog'
 SET max_parallel_workers_per_gather TO '0'
 SET max_parallel_maintenance_workers TO '0'
AS $function$
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
