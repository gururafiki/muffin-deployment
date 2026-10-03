-- A resource fired by its own pg_cron job reads as scheduled, so the stalled-resource alert can see
-- it. Migration 20261003120000.
--
-- WHY THIS EXISTS. `derive-classifications` failed every daily run from 2026-09-27 to 10-03 and no
-- alert fired: its rotation row is disabled because it runs on its own job, and `scheduled` only
-- counted the rotation. The alert skips what is not scheduled.
--
-- CI's Postgres has no pg_cron, so the fixture builds the one table the function reads, inside the
-- transaction. Each resource makes one rule the only thing deciding its answer:
--
--   t103-own-job      an active job, a disabled rotation row: scheduled (the case that was missed)
--   t103-paused-job   its only job is inactive: not scheduled
--   t103-rotation     an enabled rotation row, no job: scheduled, as before
--   t103-retired      a disabled rotation row, no job: not scheduled, as before
--   t103-other-job    a job that fires something else names no resource of its own

\set ON_ERROR_STOP on

begin;

-- WITHOUT pg_cron THE VIEW STILL READS. CI and a rebuilt database have no `cron.job`, and every
-- reader of `resource_health` (Grafana, market-verify) would error if the function assumed one.
do $$
begin
  if to_regclass('cron.job') is null then
    if (select count(*) from market.cron_scheduled_resources()) <> 0 then
      raise exception 'cron_scheduled_resources() returned rows with no cron.job';
    end if;
    perform count(*) from market.resource_health;
    raise notice 'ok  with no pg_cron the function returns nothing and resource_health still reads';
  end if;
end $$;

create schema if not exists cron;
create table if not exists cron.job (
  jobid    bigserial primary key,
  jobname  text,
  schedule text,
  command  text,
  active   boolean default true
);

insert into cron.job (jobname, schedule, command, active) values
  ('t103-a', '1 * * * *', 'select market.cron_post(''t103-own-job'')', true),
  ('t103-b', '2 * * * *', 'select market.cron_post(''t103-paused-job'')', false),
  ('t103-c', '3 * * * *', 'select market.refresh_facets()', true);

insert into market.cron_resource (resource, enabled, position) values
  ('t103-own-job', false, 10301), ('t103-rotation', true, 10302), ('t103-retired', false, 10303)
on conflict (resource) do update set enabled = excluded.enabled;

insert into market.refresh_run (resource, started_at, finished_at, ok, skipped) values
  ('t103-own-job',    now() - interval '2 days', now() - interval '2 days', true, false),
  ('t103-paused-job', now() - interval '2 days', now() - interval '2 days', true, false),
  ('t103-rotation',   now() - interval '2 days', now() - interval '2 days', true, false),
  ('t103-retired',    now() - interval '2 days', now() - interval '2 days', true, false),
  ('t103-other-job',  now() - interval '2 days', now() - interval '2 days', true, false);

do $$
declare bad text;
begin
  select string_agg(format('%s = %s', resource, scheduled), ', ' order by resource) into bad
    from market.resource_health
   where resource like 't103-%'
     and scheduled is distinct from (resource in ('t103-own-job', 't103-rotation'));
  if bad is not null then
    raise exception 'resource_health.scheduled is wrong for: % (expected true only for t103-own-job and t103-rotation)', bad;
  end if;
  raise notice 'ok  a resource on its own active job is scheduled; a paused job, a retirement and an unrelated job are not';
end $$;

rollback;
