CREATE OR REPLACE FUNCTION market.sample_backlog_estimate(p_backlog text, p_sampled_at timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  plan jsonb;
  n    bigint;
  t0   timestamptz := clock_timestamp();
begin
  if not exists (select 1 from market.backlogs_to_sample() b where b = p_backlog) then
    raise exception 'not a backlog: %', p_backlog;
  end if;

  -- EXPLAIN without ANALYZE: the planner's estimate. No execution, no scan.
  execute format('explain (format json) select 1 from market.%I', p_backlog) into plan;
  n := (plan -> 0 -> 'Plan' ->> 'Plan Rows')::bigint;

  insert into market.backlog_sample (sampled_at, backlog, depth, duration_ms, error, estimated)
       values (p_sampled_at, p_backlog, n,
               extract(epoch from clock_timestamp() - t0) * 1000,
               'exact count timed out; planner estimate', true)
  on conflict (sampled_at, backlog) do update
     set depth = excluded.depth, duration_ms = excluded.duration_ms,
         error = excluded.error, estimated = true;

  return n;
end $function$;
