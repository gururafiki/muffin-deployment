-- THE SCHEDULER BELONGS IN THE DATABASE.
--
-- GitHub Actions was not running the warm-up. Measured over four days, 2026-08-24..27:
--
--     19 scheduled runs against 32 expected     (6.8/day vs a nominal 8)
--     every single run late: 19 to 127 minutes  (median ~35)
--     gaps: min 2.5h, max 13.3h                 (nominal 3h)
--     on 08-27: ONE run, at 12:44 — the 14:10, 17:10 and 20:10 slots all missed
--
-- Scheduled workflows are best-effort on shared runners. The consequences were not subtle: the
-- observability sampler only runs when the warm-up does, so every dashboard had three data points
-- and looked broken; and the **13.3-hour maximum gap EXCEEDS the 12-hour "resource has stopped
-- succeeding" alert**, meaning GitHub's flakiness would eventually fire our own alert as a false
-- positive.
--
-- Everything needed was already installed — `pg_cron` 1.6.4 is in `shared_preload_libraries` (so
-- no restart), `pg_net` 0.20.3 is installed, and `cron.database_name` is already `postgres`.
--
-- ── WHY A ROTATION AND NOT A SWEEP ────────────────────────────────────────────────────────────
--
-- PACING IS LOAD-BEARING and `pg_net` is fire-and-forget. A single job posting 38 requests would
-- burst them all at once, and this pipeline's history is explicit about the cost: seventeen
-- resources back to back is what tripped yfinance's rate limit on 2026-08-13 and negative-cached
-- ~8,300 securities as permanently unanswerable.
--
-- So one resource every five minutes, from a cursor. 38 x 5 min = a full sweep every 3.2 hours,
-- which matches the old nominal cadence with gentler spacing than the 30s sleep it replaces — and
-- it CANNOT burst by construction. A missed firing delays the rotation by five minutes rather
-- than losing a whole sweep, which is the failure mode being replaced.
--
-- ── WHY `observability-sample` IS NOT IN THE ROTATION ─────────────────────────────────────────
--
-- It touches no external provider, so it is free to run often — and its rate is exactly what
-- decides whether a dashboard shows a line or a single dot. It gets its own hourly job: 24
-- samples a day against a nominal 16 before, at no provider cost.

-- WRAPPED because the migration tests run on plain `postgres:17-alpine`, which has no pg_cron.
-- Everything below except the schedule itself works without it — see `cron_next()`, which is
-- deliberately pure so the rotation can be TESTED in CI rather than only in production.
do $$ begin
  create extension if not exists pg_cron;
exception when others then
  raise notice '  --  pg_cron unavailable (%): tables and cursor logic still apply', sqlerrm;
end $$;

-- ── What to call, and in what order ───────────────────────────────────────────────────────────
--
-- This table is now THE SOURCE OF TRUTH for what is scheduled, replacing the `RESOURCES=$(printf
-- ...)` block in market-warmup.yml. `logic-check.ts` parses the seed below for the guard that
-- catches a resource which is registered, deployed, reachable — and never actually invoked.
-- `exchange-listings` sat in exactly that state for weeks: it is the ONLY resource that grows the
-- universe beyond what the tracked funds hold, and nothing ran it.
--
-- `position` is spaced by 10 so a resource can be inserted between two others without renumbering.
-- Order is preserved from the workflow: cheapest first, and `security-yahoo-symbols` before the
-- resources that consume symbols, because a symbol it resolves clears that security's negative
-- caches and the later passes pick it up in the same sweep.
create table if not exists market.cron_resource (
  position integer primary key,
  resource text    not null unique,
  enabled  boolean not null default true
);

insert into market.cron_resource (position, resource) values
  (0,   'sector-performance'),
  (10,  'country-performance'),
  (20,  'group-performance'),
  (30,  'instrument-performance'),
  (40,  'instrument-profile'),
  (50,  'instrument-prices'),
  (60,  'security-local-symbols'),
  (70,  'security-tickers'),
  (80,  'fx-rates'),
  (90,  'exchange-listings'),
  (100, 'security-yahoo-symbols'),
  (110, 'security-profiles'),
  (120, 'security-profile-detail'),
  (130, 'earnings-calendar'),
  (140, 'security-insider'),
  (150, 'security-filings'),
  (160, 'security-management'),
  (170, 'security-eps-history'),
  (180, 'security-industries'),
  (190, 'security-fundamentals'),
  (200, 'security-statements'),
  (210, 'security-quarters'),
  (220, 'security-metrics'),
  (230, 'sec-cik-map'),
  (240, 'security-xbrl'),
  (250, 'security-share-stats'),
  (260, 'security-news'),
  (270, 'security-symbol-repair'),
  (280, 'security-corporate-actions'),
  (290, 'security-dividends'),
  (300, 'security-performance'),
  (310, 'security-prices'),
  (320, 'security-price-history'),
  (330, 'fund-holdings'),
  (340, 'derive-classifications'),
  (350, 'macro-indicators'),
  (360, 'promote-wave'),
  (370, 'facets-refresh')
on conflict (position) do update set resource = excluded.resource;

-- Where the rotation currently is. One row, enforced by the check constraint — a cursor with two
-- rows would advance twice per tick and silently skip every other resource.
create table if not exists market.cron_cursor (
  only_row    boolean primary key default true check (only_row),
  position    integer not null default -1,
  advanced_at timestamptz not null default now()
);
insert into market.cron_cursor (only_row) values (true) on conflict do nothing;

-- ── The cursor, PURE ──────────────────────────────────────────────────────────────────────────
--
-- Advancing the rotation is separated from posting it, and that is not tidiness: `pg_net` and
-- `vault` do not exist in the migration-test image, so a combined function could only ever be
-- exercised in production. The rotation — which resource is next, that every one is reached, that
-- it wraps — is the part with logic worth testing, and it now runs in CI against plain Postgres.
--
-- ADVANCE FIRST, THEN READ. A tick that fails to post must still have moved the cursor, or one
-- unreachable resource blocks the rotation for ever — the weight-ordered-backlog stall this
-- codebase has hit five times, in a new costume.
--
-- MODULO OVER THE ENABLED COUNT, so adding or disabling a resource adapts with no cursor
-- arithmetic to get wrong.
create or replace function market.cron_next()
returns text
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  n      integer;
  pos    integer;
  target text;
begin
  select count(*) into n from market.cron_resource where enabled;
  if n = 0 then
    return null;
  end if;

  update market.cron_cursor
     set position = (position + 1) % n, advanced_at = now()
   where only_row
  returning position into pos;

  select resource into target
    from (select resource, row_number() over (order by position) - 1 as rn
            from market.cron_resource where enabled) q
   where rn = pos;

  return target;
end $$;

-- ── The post ──────────────────────────────────────────────────────────────────────────────────
--
-- THE KEY IS READ FROM `vault`, NEVER FROM THIS FILE. Migrations are piped into psql with no
-- variable substitution, so a key here would be a key in git. Ansible writes it; if it is absent
-- this returns a reason and posts NOTHING, rather than firing 288 unauthenticated requests a day.
--
-- `timeout_milliseconds` is 120,000 and that is not padding: pg_net's DEFAULT IS 5,000 while the
-- edge function's own budget is 90 seconds, so the default would record every single call as a
-- failure in `net._http_response` while the function was in fact succeeding — which looks like an
-- outage and is not.
create or replace function market.cron_post(p_resource text)
returns text
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare key text; base text;
begin
  if p_resource is null then return 'no enabled resources'; end if;

  select decrypted_secret into key  from vault.decrypted_secrets where name = 'service_role_key';
  select decrypted_secret into base from vault.decrypted_secrets where name = 'functions_base_url';
  if key is null or key = '' or base is null or base = '' then
    return 'vault secrets missing — nothing posted for ' || p_resource;
  end if;

  perform net.http_post(
    url     := base || '/market-refresh',
    body    := jsonb_build_object('resource', p_resource),
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'apikey',        key,
                 'Authorization', 'Bearer ' || key),
    timeout_milliseconds := 120000
  );
  return p_resource;
end $$;

create or replace function market.cron_tick()
returns text
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
begin
  return market.cron_post(market.cron_next());
end $$;

-- The observability sampler, on its own schedule. Same body, fixed resource.
create or replace function market.cron_sample()
returns text
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
begin
  return market.cron_post('observability-sample');
end $$;

-- ── The schedule ──────────────────────────────────────────────────────────────────────────────
--
-- `cron.schedule(name, ...)` UPSERTS on the name, so re-applying this migration updates the job
-- rather than creating a duplicate — which matters because these run on every deploy.
do $$ begin
  perform cron.schedule('muffin-rotation',      '*/5 * * * *', 'select market.cron_tick()');
  perform cron.schedule('muffin-observability', '4 * * * *',   'select market.cron_sample()');
  -- pg_cron NEVER TRIMS `job_run_details`. At 288 + 24 rows a day it is 114,000 a year, and it is
  -- also the only record of whether the scheduler fired at all — so it is pruned, not disabled.
  perform cron.schedule('muffin-cron-prune',    '17 4 * * *',
    $prune$ delete from cron.job_run_details where end_time < now() - interval '30 days' $prune$);
exception when others then
  -- A fresh database in CI has no `cron` schema until the extension initialises. The schedule is
  -- re-applied on every deploy, so skipping here costs nothing and lets the migration tests run.
  raise notice '  --  could not schedule pg_cron jobs (%): they will be scheduled on the next apply', sqlerrm;
end $$;

revoke all on function market.cron_next()   from public;
revoke all on function market.cron_post(text) from public;
revoke all on function market.cron_tick()   from public;
revoke all on function market.cron_sample() from public;
grant select on market.cron_resource, market.cron_cursor to service_role, metrics_ro;
grant select, insert, update, delete on market.cron_resource, market.cron_cursor to service_role;

alter table market.cron_resource enable row level security;
alter table market.cron_cursor   enable row level security;
do $$ begin
  drop policy if exists cron_resource_read on market.cron_resource;
  create policy cron_resource_read on market.cron_resource for select to metrics_ro using (true);
  drop policy if exists cron_cursor_read on market.cron_cursor;
  create policy cron_cursor_read on market.cron_cursor for select to metrics_ro using (true);
end $$;

-- ── Watching the scheduler itself ─────────────────────────────────────────────────────────────
--
-- Removing GitHub Actions makes pg_cron the ONLY thing driving the pipeline, and its failure mode
-- is silent: the data simply stops being refreshed and every count stays plausible for days.
--
-- But pg_cron is MORE observable than GitHub ever was. `cron.job_run_details` records every
-- firing INSIDE the database, where the sampler can read it — GitHub's reliability was invisible
-- to monitoring, which is why nobody noticed it dropping 40% of runs. This view is what
-- `sample_universe()` reads to emit `scheduler.*`, and what the "scheduler has gone silent" alert
-- fires on.
--
-- SECURITY INVOKER is wrong here and DEFINER is deliberate: `cron.job_run_details` is owned by the
-- superuser and `metrics_ro` cannot read it directly.
create or replace function market.scheduler_health()
returns table (ticks_1h bigint, failed_1h bigint, minutes_since_tick numeric)
language plpgsql
security definer
set search_path = cron, pg_catalog, pg_temp
as $$
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
end $$;

revoke all on function market.scheduler_health() from public;
grant execute on function market.scheduler_health() to service_role, metrics_ro;

notify pgrst, 'reload schema';
