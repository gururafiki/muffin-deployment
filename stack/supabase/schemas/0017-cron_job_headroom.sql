CREATE OR REPLACE FUNCTION market.cron_job_headroom()
 RETURNS TABLE(jobname text, bound_s double precision, slowest_s double precision, runs bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
begin
  if to_regclass('cron.job') is null or to_regclass('cron.job_run_details') is null then
    return;
  end if;
  return query execute $q$
    select j.jobname::text,
           extract(epoch from (regexp_match(j.command, 'statement_timeout\s*=\s*''([^'']+)'''))[1]::interval)::float8,
           max(extract(epoch from d.end_time - d.start_time))::float8,
           count(d.*)
      from cron.job j
      left join cron.job_run_details d
        on d.jobid = j.jobid and d.start_time > now() - interval '24 hours' and d.end_time is not null
     where j.active
       and j.command ~ 'statement_timeout\s*=\s*'''
     group by j.jobname, j.command
  $q$;
end;
$function$;
