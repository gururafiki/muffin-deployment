CREATE OR REPLACE FUNCTION market.scheduler_health()
 RETURNS TABLE(ticks_1h bigint, failed_1h bigint, minutes_since_tick numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cron', 'pg_catalog', 'pg_temp'
AS $function$
begin
  return query
  select
    count(*) filter (where start_time > now() - interval '1 hour'),
    count(*) filter (where start_time > now() - interval '1 hour' and status <> 'succeeded'),
    round(extract(epoch from (now() - max(start_time))) / 60.0, 1)
  from cron.job_run_details;
exception when others then
  -- No pg_cron (the migration-test image). Report nothing rather than failing the sampler.
  return;
end $function$;
