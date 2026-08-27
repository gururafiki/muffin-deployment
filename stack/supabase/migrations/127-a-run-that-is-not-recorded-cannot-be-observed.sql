-- A RUN THAT IS NOT RECORDED CANNOT BE OBSERVED.
--
-- `market.refresh_log` is keyed `resource text PRIMARY KEY` — ONE row per resource, overwritten on
-- every run. That is correct for what it is (the mutex `begin_refresh` claims), and it means this
-- pipeline has NO HISTORY BY CONSTRUCTION. Measured against production 2026-08-27: the table held
-- exactly one row per resource from the 23:xx sweep, every one `ok: true`, and not one number about
-- what any of them did. `security-prices` had run for 58 seconds; whether it wrote 3,000 rows or
-- zero is unrecoverable.
--
-- Meanwhile every resource ALREADY computes the answer and returns it — `written`, `remaining`,
-- `covered`, `failed`, `batchesFailed`, `emptySeries`, `unanswered`, `lastError` — and
-- `market-warmup.yml` does `head -c 300` and echoes it into a GitHub Actions log. 38 resources x 8
-- runs a day is **304 run reports a day, deleted**.
--
-- So this migration adds no new measurement. It writes down the measurements that already exist.
--
-- ── WHY THREE TABLES AND NOT ONE ──────────────────────────────────────────────────────────────
--
--   refresh_run     what one INVOCATION did          — written by the edge function, per run
--   backlog_sample  how much work is LEFT            — sampled, because a backlog is a view
--   universe_sample how much data we HOLD            — sampled, same reason
--
-- The first is an event and the other two are gauges; joining them would force a sample rate on
-- the events or an event on the gauges.
--
-- ── DO NOT MAKE THE DASHBOARD READ THE BACKLOG VIEWS ──────────────────────────────────────────
--
-- This is the load-bearing reason `backlog_sample` exists at all. Timed on production 2026-08-27,
-- one `count(*)` over each of the 26 `pending_*` views:
--
--     pending_prices        5,380 ms      <-- alone, two thirds of the total
--     pending_price_history   719 ms
--     pending_ttm             397 ms
--     pending_performance     290 ms
--     ... 22 others           < 200 ms each
--     TOTAL                 ~8,400 ms
--
-- That is ABOVE the 8-second statement timeout the PostgREST role carries, so counting all 26 in
-- one statement is already at the cliff — and a dashboard refreshing every 30s would run it
-- continuously against the same database the app reads. Sampling costs the same 8 seconds sixteen
-- times a DAY and every reader after that is an indexed select.
--
-- By contrast `count(*)` over EVERY market table — 63 of them, including `security_price` at
-- 10,874,625 rows — totals **771 ms**. The tables are cheap and the views are not, which is why
-- only `sample_backlogs` carries a deadline and per-item isolation.

-- ── The role Grafana and postgres-exporter connect as ─────────────────────────────────────────
--
-- NOLOGIN and passwordless HERE on purpose. Migrations are applied by piping the file into
-- `psql -U postgres` (ansible/muffin_stack.yml) with NO variable substitution, so a password
-- cannot reach this file without being committed. Ansible grants LOGIN + PASSWORD separately from
-- secrets.yaml. A role that cannot log in is inert, so this is safe to ship on its own.
--
-- NOT `service_role`. That key is the ingest's admin credential; a dashboard is a reader.
do $$ begin
  create role metrics_ro nologin;
exception when duplicate_object then null; end $$;

-- A dashboard query that runs away must not be able to block a deploy. Measured the hard way on
-- this stack: an exploratory query held locks for 1,375 seconds and the deploy 20 minutes later sat
-- behind it — `create view market.security_current` blocked for 308s — while CI showed only
-- "Terraform apply, in progress". A client timeout is not a server timeout.
alter role metrics_ro set statement_timeout = '10s';

-- Best-effort: postgres-exporter wants pg_monitor for pg_stat_*. Grafana does NOT need it — it
-- only reads the sample tables below — so a deployment where `postgres` cannot grant a predefined
-- role degrades to "no server-internals dashboard" rather than failing the whole deploy.
do $$ begin
  grant pg_monitor to metrics_ro;
exception when insufficient_privilege or undefined_object then
  raise notice '  --  could not grant pg_monitor to metrics_ro; postgres-exporter server stats will be limited';
end $$;

-- ── 1. What one invocation did ────────────────────────────────────────────────────────────────
create table if not exists market.refresh_run (
  run_id      bigserial   primary key,
  resource    text        not null,
  started_at  timestamptz not null,
  finished_at timestamptz not null default now(),
  duration_ms integer,
  -- `ok` is the RESOURCE's own verdict, taken from the body. Since 2026-08-13 an application
  -- failure answers 200 with `"ok": false` and 5xx is reserved for a genuinely dead worker, so the
  -- HTTP status alone is not the verdict — `http_status` is kept beside it precisely so the two can
  -- be compared. A bare 502 with no body still means the worker died.
  ok          boolean     not null,
  -- `{ skipped: true, reason: 'fresh or in flight' }` is a SUCCESS: the TTL guard did its job and
  -- no upstream call was made. Recording it as an error would make every warm-up look half-broken,
  -- and recording it as an ordinary success would make a resource that never actually runs look
  -- healthy. It is its own fact.
  skipped     boolean     not null default false,
  http_status integer,
  error       text,
  report      jsonb,

  -- GENERATED, not written by the caller. Field names differ per resource and the report is the
  -- source of truth; a column the writer has to remember to fill is a column that drifts from it.
  --
  -- `jsonb_typeof(...) = 'number'` is mandatory rather than defensive: a numeric-looking STRING
  -- casts cleanly and stores a wrong type silently, while a value like `"n/a"` RAISES — and since
  -- migrations apply under `--single-transaction`, that aborts the entire deploy.
  written   bigint generated always as
              (case when jsonb_typeof(report -> 'written')   = 'number'
                    then (report ->> 'written')::bigint end) stored,
  remaining bigint generated always as
              (case when jsonb_typeof(report -> 'remaining') = 'number'
                    then (report ->> 'remaining')::bigint end) stored,
  failed    bigint generated always as
              (case when jsonb_typeof(report -> 'failed')    = 'number'
                    then (report ->> 'failed')::bigint end) stored
);

create index if not exists refresh_run_resource_started_idx on market.refresh_run (resource, started_at desc);
create index if not exists refresh_run_started_idx          on market.refresh_run (started_at desc);

-- ── 2. How much work is left ──────────────────────────────────────────────────────────────────
create table if not exists market.backlog_sample (
  sampled_at  timestamptz not null,
  backlog     text        not null,
  -- NULL means "we could not count it", which is NOT the same fact as zero. A backlog view that
  -- has started timing out reads as drained if its failure is recorded as an empty result — the
  -- exact confusion between "the provider refused" and "the provider has nothing" that this
  -- pipeline has now hit six times. `error` says which.
  depth       bigint,
  duration_ms integer,
  error       text,
  primary key (sampled_at, backlog)
);

create index if not exists backlog_sample_backlog_idx on market.backlog_sample (backlog, sampled_at desc);

-- ── 3. How much data we hold ──────────────────────────────────────────────────────────────────
--
-- LONG FORMAT (metric, value) rather than a column per fact, so adding a measurement is a row and
-- never a migration — the same reason `market.macro_indicator` and `market.metric` are control
-- tables. It also means the metric set is DISCOVERED (see sample_universe) rather than authored,
-- which is what stops it silently missing a table added later.
create table if not exists market.universe_sample (
  sampled_at timestamptz not null,
  metric     text        not null,
  value      numeric,
  primary key (sampled_at, metric)
);

create index if not exists universe_sample_metric_idx on market.universe_sample (metric, sampled_at desc);

-- ── Sampling the backlogs ─────────────────────────────────────────────────────────────────────
--
-- Discovered from `pg_class`, NEVER a hardcoded list. `pending_%` is already a load-bearing naming
-- convention — `every-table-is-reachable.sql` classifies a view as a service-role work queue by
-- that prefix — and a hand-maintained list of the same objects drifts within weeks: migration 106
-- rebuilt `symbol_cache_classification` from migration 050's nine entries and silently deleted the
-- eight added since.
--
-- PER-BACKLOG ISOLATION, for the reason the numbers above give: one view costs 5.4s of an 8s
-- budget, so a single slow view must not be able to lose the other 25 samples. And a deadline on
-- top, because 26 x 10s is longer than the edge worker's whole 90s budget.
create or replace function market.sample_backlogs(
  p_deadline_seconds integer default 60,
  p_each_timeout     text    default '10s'
) returns integer
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  v        text;
  n        bigint;
  t0       timestamptz;
  deadline timestamptz := clock_timestamp() + make_interval(secs => p_deadline_seconds);
  ts       timestamptz := now();
  taken    integer := 0;
begin
  -- Transaction-local, so it cannot leak to whatever else this connection does next.
  perform set_config('statement_timeout', p_each_timeout, true);

  for v in
    select c.relname
      from pg_class c
      join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'market'
       and c.relkind in ('v', 'm')
       and c.relname like 'pending\_%'
     order by c.relname
  loop
    -- Out of time. Stop rather than half-answer: a row recorded now would be attributed to `ts`
    -- and read as a measurement taken at the same instant as the others.
    exit when clock_timestamp() > deadline;

    t0 := clock_timestamp();
    begin
      execute format('select count(*) from market.%I', v) into n;
      insert into market.backlog_sample (sampled_at, backlog, depth, duration_ms, error)
           values (ts, v, n, extract(epoch from clock_timestamp() - t0) * 1000, null)
      on conflict (sampled_at, backlog) do nothing;
    exception when others then
      -- `duration_ms` is kept on the failure path too: a view that is getting slower shows up here
      -- as a rising time long before it starts timing out.
      insert into market.backlog_sample (sampled_at, backlog, depth, duration_ms, error)
           values (ts, v, null, extract(epoch from clock_timestamp() - t0) * 1000, left(sqlerrm, 300))
      on conflict (sampled_at, backlog) do nothing;
    end;
    taken := taken + 1;
  end loop;

  return taken;
end $$;

-- ── Sampling the universe ─────────────────────────────────────────────────────────────────────
--
-- Every table is counted and sized, discovered from `pg_tables`. That is affordable BECAUSE it was
-- measured: 771 ms for all of them (see the header). An authored list would have to be extended
-- every time a table is added, and the one that got forgotten would be invisible — which is the
-- failure this file exists to stop.
--
-- The `%_missing_at` populations are counted separately and deliberately: they are the negative
-- caches, and a JUMP in one is the signature of a provider outage being recorded as fact about
-- thousands of securities. ~8,300 were marked permanently unanswerable in a single afternoon on
-- 2026-08-13 — INTC, PEP, XOM and REGN among them — while every other count stayed plausible.
create or replace function market.sample_universe()
returns integer
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  r     record;
  n     bigint;
  ts    timestamptz := now();
  taken integer := 0;
begin
  perform set_config('statement_timeout', '30s', true);

  -- Row counts and on-disk size, per table.
  for r in
    select tablename from pg_tables where schemaname = 'market' order by tablename
  loop
    begin
      execute format('select count(*) from market.%I', r.tablename) into n;
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, 'rows.' || r.tablename, n)
      on conflict do nothing;

      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, 'bytes.' || r.tablename,
                   pg_total_relation_size(format('market.%I', r.tablename)::regclass))
      on conflict do nothing;
      taken := taken + 2;
    exception when others then null;   -- one unreadable table must not lose the rest
    end;
  end loop;

  -- Negative-cache populations. `pg_attribute`, NOT `information_schema.columns`: the latter
  -- reports ZERO columns for a materialized view, so a check written against it fails for a reason
  -- unrelated to what it tests.
  for r in
    select c.relname as tbl, a.attname as col
      from pg_class c
      join pg_namespace ns on ns.oid = c.relnamespace
      join pg_attribute a  on a.attrelid = c.oid
     where ns.nspname = 'market'
       and c.relkind = 'r'
       and a.attnum > 0
       and not a.attisdropped
       and a.attname like '%\_missing\_at'
     order by c.relname, a.attname
  loop
    begin
      execute format('select count(*) from market.%I where %I is not null', r.tbl, r.col) into n;
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, format('missing.%s.%s', r.tbl, r.col), n)
      on conflict do nothing;
      taken := taken + 1;
    exception when others then null;
    end;
  end loop;

  -- The handful of FILTERED counts market-verify.yml already asserts floors on. Kept explicit so
  -- the dashboard trends the same numbers the nightly check passes or fails on — a dashboard that
  -- disagrees with the gate is worse than no dashboard.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, m, v from (
    select 'equities'              as m, count(*)::numeric as v from market.security where security_type_code = 'equity'
    union all
    select 'identifiers.isin',   count(*) from market.security_identifier where kind_code = 'isin'
    union all
    select 'identifiers.ticker', count(*) from market.security_identifier where kind_code = 'ticker'
    union all
    select 'identifiers.cusip',  count(*) from market.security_identifier where kind_code = 'cusip'
    union all
    select 'tracked_funds.enabled',  count(*) from market.tracked_fund where enabled = true
    union all
    select 'tracked_funds.ingested', count(*) from market.tracked_fund where last_report_date is not null
  ) s
  on conflict do nothing;

  return taken + 6;
end $$;

-- ── Retention ─────────────────────────────────────────────────────────────────────────────────
--
-- 400 days, so a full year of history is always available for a year-on-year comparison and the
-- table is still bounded. Same shape as the 90-day prunes on `earnings_calendar` and
-- `security_news`, and watched the same way: a table that only GROWS looks exactly like a healthy
-- one, so `check_retention_is_enforced.py` asserts the ceiling rather than trusting this runs.
create or replace function market.prune_observability(p_days integer default 400)
returns integer
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  cutoff timestamptz := now() - make_interval(days => p_days);
  n      integer := 0;
  d      integer;
begin
  delete from market.refresh_run     where started_at < cutoff;  get diagnostics d = row_count; n := n + d;
  delete from market.backlog_sample  where sampled_at < cutoff;  get diagnostics d = row_count; n := n + d;
  delete from market.universe_sample where sampled_at < cutoff;  get diagnostics d = row_count; n := n + d;
  return n;
end $$;

-- ── Grants and RLS ────────────────────────────────────────────────────────────────────────────
--
-- service_role needs SELECT and INSERT on every market table or `every-table-is-reachable.sql`
-- fails — and that check exists because a table can be created, apply cleanly four times, pass
-- everything, and still be unreachable in production for want of one grant.
grant select, insert, update, delete
   on market.refresh_run, market.backlog_sample, market.universe_sample
   to service_role;

grant usage on schema market to metrics_ro;
grant select on market.refresh_run, market.backlog_sample, market.universe_sample to metrics_ro;
grant usage, select on sequence market.refresh_run_run_id_seq to service_role;

alter table market.refresh_run     enable row level security;
alter table market.backlog_sample  enable row level security;
alter table market.universe_sample enable row level security;

-- An explicit read policy for the ONE role that reads these, rather than `refresh_log`'s
-- no-policy-at-all. RLS with no policy denies every role without BYPASSRLS, which would include
-- Grafana — and the failure mode is an empty panel, not an error. anon and authenticated are
-- denied by having no grant at all, so this is belt and braces rather than the only barrier.
do $$
declare t text;
begin
  foreach t in array array['refresh_run', 'backlog_sample', 'universe_sample'] loop
    execute format('drop policy if exists %I on market.%I', t || '_metrics_ro_read', t);
    execute format(
      'create policy %I on market.%I for select to metrics_ro using (true)',
      t || '_metrics_ro_read', t);
  end loop;
end $$;

-- The samplers WRITE, so they are service_role only. `create or replace function` PRESERVES the
-- existing ACL, so a grant here can only ever ADD a privilege — which is why the revoke from
-- public comes first and is what makes the grant load-bearing at all. Postgres grants EXECUTE to
-- PUBLIC by default and `03-security.sql` revokes only TABLES.
revoke all on function market.sample_backlogs(integer, text)  from public;
revoke all on function market.sample_universe()               from public;
revoke all on function market.prune_observability(integer)    from public;
grant execute on function market.sample_backlogs(integer, text) to service_role;
grant execute on function market.sample_universe()             to service_role;
grant execute on function market.prune_observability(integer)  to service_role;

notify pgrst, 'reload schema';
