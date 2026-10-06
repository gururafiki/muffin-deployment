-- THE TWO ROLES THE SCHEMA GRANTS TO, WHICH NOTHING ELSE CREATES.
--
-- `metrics_ro` (Grafana, postgres-exporter) and `ingest_rw` (the Dagster worker) were created by
-- legacy migrations 127 and 206. Those were retired into `migrations-legacy/` at the 2026-09-10
-- cutover, and the baseline that replaced them is a dump of three SCHEMAS — roles are cluster-wide,
-- so they are not in it. The baseline grants to both roles, so on a database built from the repo it
-- failed at its first policy (`role "metrics_ro" does not exist`, reproduced 2026-09-19).
--
-- APPLIED BY ANSIBLE BEFORE `supabase db push`, ON EVERY DEPLOY, AND IT ONLY EVER CREATES. A role
-- that exists is left exactly as it is: production's roles have LOGIN and a password (set by
-- Ansible from secrets.yaml after the migrations), and re-asserting NOLOGIN here would lock both
-- consumers out on every deploy. So this gives a NEW role what the legacy set gave it — its
-- statement timeout and, for the metrics reader, `pg_monitor` — and a later change to either role
-- is a migration, which reaches production and a rebuild alike.
--
-- Not named `roles.sql` on purpose: `db/roles.sql` is the Supabase image's own init script, which
-- sets the passwords of the built-in roles, and two files of that name are an invitation to edit
-- the wrong one.
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
