-- `market.cron_job_headroom()` reports, for each active pg_cron job carrying a statement timeout,
-- that bound and its slowest run in the last 24 hours; Grafana's role may call it and the app's may
-- not (migration 20261121130000).
--
-- The migration tests run on plain Postgres with no pg_cron, so this test builds a stand-in `cron`
-- schema with the two tables the function reads, inside the transaction. The fixture makes each
-- rule load-bearing:
--   t-a  bound 300s; runs of 120 s and 210 s today, and a 290 s run two days ago: slowest 210, so a
--        window that ignores the date reads 290;
--   t-b  bound 60s, a run of 58 s: past two-thirds;
--   t-c  no statement timeout in its command: not reported;
--   t-d  inactive: not reported;
--   t-e  a bound and no run in 24 hours: reported with no slowest run;
--   t-f  bound '5min': 300 s, so the bound is parsed as an interval, not as a number of seconds;
--   t-g  a run still in flight (no end time): not counted.

\set ON_ERROR_STOP on

begin;

do $$
begin
  if to_regclass('cron.job') is not null then
    raise exception 'this test builds its own cron schema; it must run where pg_cron is absent';
  end if;
end $$;

create schema cron;
create table cron.job (jobid bigint primary key, jobname text, command text, active boolean);
create table cron.job_run_details (
  jobid bigint, start_time timestamptz, end_time timestamptz, status text);

insert into cron.job values
  (1, 't-a', $c$set statement_timeout = '300s'; select 1$c$, true),
  (2, 't-b', $c$set statement_timeout = '60s'; select 1$c$, true),
  (3, 't-c', $c$select 1$c$, true),
  (4, 't-d', $c$set statement_timeout = '300s'; select 1$c$, false),
  (5, 't-e', $c$set statement_timeout = '120s'; select 1$c$, true),
  (6, 't-f', $c$set statement_timeout = '5min'; select 1$c$, true),
  (7, 't-g', $c$set statement_timeout = '300s'; select 1$c$, true);

insert into cron.job_run_details values
  (1, now() - interval '3 hours', now() - interval '3 hours' + interval '120 seconds', 'succeeded'),
  (1, now() - interval '2 hours', now() - interval '2 hours' + interval '210 seconds', 'succeeded'),
  (1, now() - interval '2 days',  now() - interval '2 days' + interval '290 seconds', 'succeeded'),
  (2, now() - interval '1 hour',  now() - interval '1 hour' + interval '58 seconds', 'succeeded'),
  (3, now() - interval '1 hour',  now() - interval '1 hour' + interval '500 seconds', 'succeeded'),
  (4, now() - interval '1 hour',  now() - interval '1 hour' + interval '500 seconds', 'succeeded'),
  (6, now() - interval '1 hour',  now() - interval '1 hour' + interval '30 seconds', 'succeeded'),
  (7, now() - interval '1 hour',  now() - interval '1 hour' + interval '30 seconds', 'succeeded'),
  (7, now() - interval '5 minutes', null, 'running');

do $$
declare
  got text;
  want text := 't-a 300/210/2 | t-b 60/58/1 | t-e 120/-/0 | t-f 300/30/1 | t-g 300/30/1';
begin
  select string_agg(concat(jobname, ' ', bound_s, '/', coalesce(slowest_s::text, '-'), '/', runs),
                    ' | ' order by jobname)
    into got
    from market.cron_job_headroom();
  if got is distinct from want then
    raise exception E'cron_job_headroom reported the wrong jobs or figures\n got: %\nwant: %',
      got, want;
  end if;
  if (select count(*) from market.cron_job_headroom() where slowest_s > bound_s * 2 / 3) <> 2 then
    raise exception 'the alert''s rule must find the two jobs past two-thirds of their bound';
  end if;
  raise notice 'ok  each active bounded job reports its bound and its slowest run today';
end $$;

do $$
begin
  if not has_function_privilege('metrics_ro', 'market.cron_job_headroom()', 'execute') then
    raise exception 'Grafana''s role must be able to call cron_job_headroom()';
  end if;
  if has_function_privilege('anon', 'market.cron_job_headroom()', 'execute') then
    raise exception 'cron_job_headroom() reads cron as its owner: anon must not call it';
  end if;
  raise notice 'ok  only Grafana''s role may call it';
end $$;

rollback;

-- Where pg_cron is absent the function answers with nothing rather than an error.
do $$
begin
  if (select count(*) from market.cron_job_headroom()) <> 0 then
    raise exception 'with no cron schema, cron_job_headroom() must return no rows';
  end if;
  raise notice 'ok  with no pg_cron it returns nothing';
end $$;
