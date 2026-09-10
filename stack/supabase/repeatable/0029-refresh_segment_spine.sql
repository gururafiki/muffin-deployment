CREATE OR REPLACE FUNCTION market.refresh_segment_spine()
 RETURNS TABLE(rows_refreshed bigint, duration_ms integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog'
 SET max_parallel_workers_per_gather TO '0'
 SET max_parallel_maintenance_workers TO '0'
AS $function$
declare t0 timestamptz := clock_timestamp();
begin
  -- CONCURRENTLY so the refresh does not take an ACCESS EXCLUSIVE lock on the thing every
  -- aggregate reads. It needs the unique index above, and it cannot run inside a transaction
  -- block — which is why this is its own RPC rather than a step in a larger one.
  refresh materialized view concurrently market.security_segment_spine;
  return query
    -- `extract(milliseconds from ...)` ALREADY INCLUDES THE SECONDS field, so adding
    -- `1000 * extract(seconds ...)` double-counts it: a measured 6,454 ms call reported 12,436.
    -- A number that is not what its name says is the failure mode this schema is mostly about.
    select count(*)::bigint,
           (extract(epoch from clock_timestamp() - t0) * 1000)::integer
      from market.security_segment_spine;
end;
$function$;
