-- A PG_CRON JOB'S HEADROOM IS VISIBLE TO GRAFANA, AND THE QUALITY SAMPLE GETS ROOM.
--
-- WHY. The four observability samples run from pg_cron as `postgres`, each behind a leading
-- `set statement_timeout` (20261003170000, 20261003190000, 20261108130000). Measured 2026-11-21
-- from `cron.job_run_details` over 7 days, none failed, and all have grown:
--
--   muffin-quality        max  58 s of  60 s  (97%)   avg 19 s
--   muffin-coverage       max 177 s of 300 s  (59%)   avg 138 s
--   muffin-universe       max 143 s of 300 s  (48%)   avg 40 s
--   muffin-segment-spine  max 126 s of 300 s  (42%)   avg 50 s; 11 s through October, 22 s in early
--                                                      November, ~50 s since the Dagster segment
--                                                      lanes began writing on 11-15
--
-- Nothing could see this before a timeout. "An observability sample has stopped arriving" fires
-- only after a sample is hours old, and Grafana's role (`metrics_ro`) gets `permission denied for
-- schema cron`. A number trending toward a hard limit gets an alert, or the limit goes (CLAUDE.md);
-- here it gets both.
--
-- WHAT.
--   1. `muffin-quality` gets 300 s, the bound the other three carry. The sample is observability:
--      Grafana reads it, the app never does, so a longer statement costs only CPU at :06.
--   2. `market.cron_job_headroom()`, SECURITY DEFINER as `cron_scheduled_resources()` is: each
--      active job whose command carries a statement timeout, that bound, and its slowest run in the
--      last 24 hours. A run cancelled at its bound is a run, so it reports ~100%. Grafana alerts
--      when any job's slowest run passes two-thirds of its bound ("A pg_cron job is nearing its
--      time bound").
--
-- Guarded on the relation: the migration tests run on plain Postgres with no pg_cron, where the
-- function returns nothing and nothing is scheduled.

drop function if exists market.cron_job_headroom();
create function market.cron_job_headroom()
returns table (jobname text, bound_s double precision, slowest_s double precision, runs bigint)
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'pg_temp'
as $function$
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

-- A function is executable by PUBLIC by default, and a SECURITY DEFINER one reads `cron` as its
-- owner: only Grafana's role gets it.
revoke all on function market.cron_job_headroom() from public;
grant execute on function market.cron_job_headroom() to metrics_ro;

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
      $c$set statement_timeout = '300s'; select market.sample_quality()$c$)
  $q$;
end $$;
