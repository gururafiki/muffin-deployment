do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'resource_health';
  if k = 'm' then execute 'drop materialized view if exists market.resource_health cascade';
  elsif k = 'v' then execute 'drop view if exists market.resource_health cascade';
  end if;
end $$;
create view market.resource_health as
SELECT resource,
    min(started_at) AS first_seen,
    max(finished_at) FILTER (WHERE ok AND NOT skipped) AS last_worked,
    max(finished_at) FILTER (WHERE ok) AS last_ok_including_skips,
    count(*) FILTER (WHERE skipped AND started_at > (now() - '06:00:00'::interval)) AS skips_6h,
    count(*) FILTER (WHERE started_at > (now() - '06:00:00'::interval)) AS runs_6h,
    ( SELECT EXTRACT(epoch FROM l.min_interval) / 3600.0
           FROM market.refresh_log l
          WHERE l.resource = r.resource) AS ttl_hours,
    (EXISTS ( SELECT 1
           FROM market.cron_resource cr
          WHERE cr.resource = r.resource AND cr.enabled)) AS scheduled
   FROM market.refresh_run r
  WHERE started_at > (now() - '30 days'::interval)
  GROUP BY resource;
