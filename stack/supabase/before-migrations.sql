-- WHAT THE BASELINE NEEDS AND A DUMP OF THREE SCHEMAS CANNOT CARRY: TWO ROLES AND ONE EXTENSION.
--
-- The baseline is a dump of `market`, `api` and `ingest`. Roles are cluster-wide and extensions
-- live outside those schemas, so neither is in it, although the legacy migrations created both:
--
--   * `metrics_ro` (Grafana, postgres-exporter) and `ingest_rw` (the Dagster worker), legacy 127
--     and 206. The baseline grants to both, so on a database built from the repo it failed at its
--     first policy (`role "metrics_ro" does not exist`, reproduced 2026-09-19).
--   * `pg_cron`, legacy 133. Every migration that schedules a job is guarded on `cron.job`
--     existing, because CI's Postgres has no pg_cron; so on a rebuilt node, with nothing to create
--     the extension, every one of them would skip, and no job would ever run, without an error.
--
-- APPLIED BY ANSIBLE BEFORE `supabase db push`, ON EVERY DEPLOY, AND IT ONLY EVER CREATES. A role
-- that exists is left exactly as it is: production's roles have LOGIN and a password (set by
-- Ansible from secrets.yaml after the migrations), and re-asserting NOLOGIN here would lock both
-- consumers out on every deploy. So this gives a NEW role what the legacy set gave it — its
-- statement timeout and, for the metrics reader, `pg_monitor` — and a later change to either role
-- is a migration, which reaches production and a rebuild alike.
--
-- `ingest_rw`'s BYPASSRLS is not here: migration 20260911000500 grants it, and that migration runs
-- on a rebuild exactly as it ran on production.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'metrics_ro') then
    create role metrics_ro nologin;
    -- A dashboard query that runs away must not hold locks a deploy needs (legacy 127).
    alter role metrics_ro set statement_timeout = '10s';
    begin
      -- Best-effort, as in legacy 127: postgres-exporter wants pg_monitor for pg_stat_*, and a
      -- deployment where `postgres` cannot grant a predefined role loses those panels, not the
      -- deploy.
      grant pg_monitor to metrics_ro;
    exception when insufficient_privilege or undefined_object then
      raise notice '  --  could not grant pg_monitor to metrics_ro';
    end;
    raise notice '  ++  created metrics_ro';
  end if;

  if not exists (select 1 from pg_roles where rolname = 'ingest_rw') then
    create role ingest_rw nologin;
    -- A third limit, distinct from anon's 3 s and PostgREST's 8 s (legacy 206).
    alter role ingest_rw set statement_timeout = '120s';
    raise notice '  ++  created ingest_rw';
  end if;
end $$;

-- ONLY WHERE THE IMAGE SHIPS IT, which is an explicit test rather than legacy 133's
-- `exception when others`: that swallowed every failure, including a real one on the node.
-- `postgres` may create it on the Supabase image, as legacy 133 did in production.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
     and not exists (select 1 from pg_extension where extname = 'pg_cron') then
    create extension pg_cron;
    raise notice '  ++  created pg_cron';
  end if;
end $$;
