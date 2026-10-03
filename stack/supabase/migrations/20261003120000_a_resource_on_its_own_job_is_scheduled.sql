-- A resource fired by its own pg_cron job is scheduled, and the stalled-resource alert watches it.
--
-- WHY. `resource_health.scheduled` was true only for a resource with an ENABLED row in
-- `market.cron_resource`, the rotation. Every resource moved onto its own pg_cron job since
-- migration 137 has its rotation row DISABLED, so it read `scheduled = false`, and the stalled
-- alert skips anything unscheduled: "not scheduled at all is not late". Measured 2026-10-03:
-- `derive-classifications` (job `muffin-classify`) had failed every daily run since 09-27 with
-- `derive_segment_classification failed: canceling statement due to statement timeout`, last
-- success 09-26, and no alert fired. `security-metrics` (job `muffin-metrics`) read the same way.
-- Nine resources run on their own job today. This was planned with Stage 1b of the umbrella's
-- docs/specs/2026-09-26-finishing-the-universe-family.md and not shipped with it.
--
-- WHY A FUNCTION. `cron.job` exists on the node and not in CI's plain Postgres, so a view naming it
-- could not be created there; the function asks the catalogue first and reads the table through
-- dynamic SQL. And `cron.job` carries row security (`username = current_user`): SECURITY DEFINER,
-- owned by the role that created the jobs, reads all of them for whoever reads the view.
--
-- ONLY ACTIVE JOBS. An inactive job fires nothing, so a resource whose only job is paused is as
-- unscheduled as one with no job, and alerting on it would be noise.

create or replace function market.cron_scheduled_resources()
returns setof text
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'pg_temp'
as $function$
begin
  if to_regclass('cron.job') is null then
    return;
  end if;
  return query execute $q$
    select distinct (regexp_match(j.command, 'cron_post\(''([a-z0-9-]+)''\)'))[1]
      from cron.job j
     where j.active
       and j.command ~ 'cron_post\('''
  $q$;
end;
$function$;

comment on function market.cron_scheduled_resources() is
  'The resources an active pg_cron job fires through market.cron_post(), read from cron.job. Empty '
  'where pg_cron is not installed. Used by market.resource_health.';

create or replace view market.resource_health as
select resource,
       min(started_at) as first_seen,
       max(finished_at) filter (where ok and not skipped) as last_worked,
       max(finished_at) filter (where ok) as last_ok_including_skips,
       count(*) filter (where skipped and started_at > (now() - '06:00:00'::interval)) as skips_6h,
       count(*) filter (where started_at > (now() - '06:00:00'::interval)) as runs_6h,
       (select extract(epoch from l.min_interval) / 3600.0
          from market.refresh_log l
         where l.resource = r.resource) as ttl_hours,
       (exists (select 1 from market.cron_resource cr
                 where cr.resource = r.resource and cr.enabled)
        or r.resource in (select market.cron_scheduled_resources())) as scheduled
  from market.refresh_run r
 where started_at > (now() - '30 days'::interval)
 group by resource;

-- EXECUTE STAYS WITH PUBLIC, ON PURPOSE. A function called inside a view is checked against the
-- view's READER, not its owner, so every role that reads `resource_health` (anon, authenticated,
-- service_role, ingest_rw, metrics_ro) needs it. It returns resource names only, which are public in
-- this repository, never a job's command text.

-- GRAFANA COULD NOT READ WHAT ITS OWN ALERT AND PANELS ASK FOR. `metrics_ro` is granted table by
-- table, and these fifteen were never granted. Measured on production 2026-10-03:
--   * `resource_health`: the stalled-resource alert's only input, so the rule errored on every
--     evaluation (`permission denied`), with `execErrState: Alerting`. A rule that is always in
--     error reads exactly like one that is always firing, and `derive-classifications` failed every
--     day for a week behind it.
--   * the whole Business lines dashboard (`security`, the segment tables and views,
--     `security_filing`, `security_metric`, `security_industries`, the four segment backlogs and
--     `pending_segment_alias`). Every panel errored as provisioned.
--   * `ticker_disagreement`, on the Universe dashboard.
-- Each of these tables already carries a read policy for PUBLIC, so the grant is the only gate.
-- `.github/scripts/check_grafana_reads_are_granted.py` now fails CI on any relation a provisioned
-- panel or alert reads and `metrics_ro` cannot.
grant select on
  market.resource_health,
  market.security,
  market.security_filing,
  market.security_industries,
  market.security_metric,
  market.security_segment,
  market.security_segment_geography,
  market.security_segment_latest,
  market.security_segment_spine,
  market.ticker_disagreement,
  market.pending_segments,
  market.pending_cn_segments,
  market.pending_in_segments,
  market.pending_kr_segments,
  market.pending_segment_alias
to metrics_ro;
