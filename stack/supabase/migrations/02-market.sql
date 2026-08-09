-- Muffin market-reference + market-performance tables — IDEMPOTENT (re-applied on
-- every deploy by muffin_stack.yml, same as 01-app.sql).
--
-- WHY A DEDICATED `market` SCHEMA (and not `public`):
--   LangGraph deliberately keeps ITS tables in `public` (see muffin_stack.yml — a
--   `langgraph` schema was attempted and abandoned because langgraph-api recreates
--   its tables in public whenever they're missing). Supabase's bootstrap grants the
--   `anon` role SELECT on public tables, which is exactly how LangGraph's thread /
--   checkpoint tables ended up world-readable through PostgREST (see 03-security.sql).
--   Keeping market data in its own schema means every grant here is explicit, and
--   nothing we add inherits that default.
--
-- Requires `market` in PGRST_DB_SCHEMAS (docker-compose.yaml, supabase-rest AND
-- supabase-studio) — PostgREST only exposes schemas named there. Clients reach it
-- with `supabase.schema('market')`, or `Accept-Profile: market` over raw REST.
--
-- Access model: reference + performance rows are PUBLIC READ (they are market facts,
-- identical for every user, and the globe must render before sign-in). All writes are
-- service_role only — the `market-refresh` edge function.

create schema if not exists market;

grant usage on schema market to anon, authenticated, service_role;

-- === Reference: sectors ======================================================
-- Seeded below from muffin-ui's authored SECTORS so the app can stop bundling them.
-- `icon` is a muffin-ui IconName (components/icons/registry.ts), not a file path.
create table if not exists market.sectors (
  id         text primary key,
  name       text not null,
  icon       text,
  sort_order integer not null default 0
);

-- === Performance snapshots ===================================================
-- ONE table for every scope so later phases (countries, instruments, classification
-- groups) add ROWS, not tables. `scope_id` is the natural key within a scope:
-- a sector id, an ISO-3166 alpha-2, a ticker, or a classification group id.
--
-- Freshness is per row: `as_of` is when the upstream reported it, `stale_after` is
-- when a reader should trigger a refresh. Readers ALWAYS serve what is here —
-- staleness triggers a background refresh, it never blocks a read.
create table if not exists market.performance (
  scope       text        not null,
  scope_id    text        not null,
  period      text        not null,
  change_pct  numeric,
  as_of       timestamptz not null default now(),
  stale_after timestamptz not null,
  source      text,
  primary key (scope, scope_id, period)
);

do $$ begin
  alter table market.performance
    add constraint performance_scope_ck
    check (scope in ('sector', 'country', 'instrument', 'group'));
exception when duplicate_object then null; end $$;

-- The canonical period vocabulary the UI's timeframe control switches over. The
-- refresh function maps each provider's own column names onto these.
do $$ begin
  alter table market.performance
    add constraint performance_period_ck
    check (period in ('1d', '1w', '1m', '3m', '6m', 'ytd', '1y', '3y', '5y', '10y'));
exception when duplicate_object then null; end $$;

create index if not exists performance_scope_period_idx
  on market.performance (scope, period);

-- === Refresh bookkeeping =====================================================
-- Doubles as the mutex for `begin_refresh` below: an unfinished row younger than
-- the in-flight window means a refresh is already running.
create table if not exists market.refresh_log (
  resource    text primary key,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  ok          boolean     not null default false,
  error       text
);

-- === Refresh claim / release =================================================
-- The refresh trigger is reachable by anyone holding the anon key (it is published
-- in runtime-config.js), so the claim MUST be atomic and self-limiting: N concurrent
-- triggers have to collapse into at most one upstream fetch.
--
-- `pg_try_advisory_xact_lock` makes the check-and-claim atomic against concurrent
-- callers (PostgREST runs each request in one transaction, so the lock is released
-- when this function returns). The refresh_log row — not the advisory lock — is what
-- guards the DURATION of the upstream fetch.
-- `create or replace function` keys on the ARGUMENT LIST, so changing the signature
-- ADDS an overload instead of replacing. Two overloads that both accept
-- (p_resource, p_min_interval) make PostgREST fail the RPC with "Could not choose
-- the best candidate function". Drop superseded signatures explicitly; add a line
-- here whenever this signature changes again.
drop function if exists market.begin_refresh(text, interval, interval);

create or replace function market.begin_refresh(
  p_resource      text,
  p_min_interval  interval default interval '5 minutes',
  p_inflight_ttl  interval default interval '2 minutes',
  p_error_backoff interval default interval '1 minute'
) returns boolean
language plpgsql
security definer
set search_path = market, pg_temp
as $$
begin
  if not pg_try_advisory_xact_lock(hashtext('market.refresh:' || p_resource)) then
    return false;
  end if;

  if exists (
    select 1 from market.refresh_log
     where resource = p_resource
       and (
         -- A successful refresh finished recently enough.
         (ok and finished_at is not null and finished_at > now() - p_min_interval)
         -- …or another refresh is still in flight (and hasn't obviously died).
         or (finished_at is null and started_at > now() - p_inflight_ttl)
         -- …or the LAST attempt failed and is still cooling off. Without this a
         -- persistently broken upstream would be re-hit on every single trigger,
         -- and the trigger is reachable by anyone holding the public anon key.
         or (not ok and finished_at is not null and finished_at > now() - p_error_backoff)
       )
  ) then
    return false;
  end if;

  insert into market.refresh_log (resource, started_at, finished_at, ok, error)
       values (p_resource, now(), null, false, null)
  on conflict (resource) do update
     set started_at = now(), finished_at = null, ok = false, error = null;

  return true;
end $$;

create or replace function market.finish_refresh(
  p_resource text,
  p_ok       boolean,
  p_error    text default null
) returns void
language sql
security definer
set search_path = market, pg_temp
as $$
  update market.refresh_log
     set finished_at = now(), ok = p_ok, error = p_error
   where resource = p_resource;
$$;

-- === Seed: sectors ===========================================================
-- Mirrors muffin-ui SECTORS (features/markets/taxonomy.ts). `on conflict do update`
-- so renames/reorders land on redeploy, and hand-edits in Studio are not preserved
-- for these columns — this file is the source of truth.
insert into market.sectors (id, name, icon, sort_order) values
  ('information-technology', 'Information Technology', 'sector-tech',          1),
  ('financials',             'Financials',             'sector-financials',    2),
  ('health-care',            'Health Care',            'sector-health',        3),
  ('consumer-discretionary', 'Consumer Discretionary', 'sector-discretionary', 4),
  ('consumer-staples',       'Consumer Staples',       'sector-staples',       5),
  ('communication-services', 'Communication Services', 'sector-comms',         6),
  ('industrials',            'Industrials',            'sector-industrials',   7),
  ('energy',                 'Energy',                 'sector-energy',        8),
  ('materials',              'Materials',              'sector-materials',     9),
  ('utilities',              'Utilities',              'sector-utilities',    10),
  ('real-estate',            'Real Estate',            'sector-realestate',   11)
on conflict (id) do update
  set name = excluded.name, icon = excluded.icon, sort_order = excluded.sort_order;

-- === Grants ==================================================================
-- Public read (market facts, pre-auth). Writes are service_role only.
grant select on market.sectors, market.performance to anon, authenticated;
grant select, insert, update, delete on market.sectors, market.performance to service_role;
grant select, insert, update, delete on market.refresh_log to service_role;

-- The claim/release pair is a WRITE path — service_role only. The client asks the
-- edge function to refresh; it never claims a refresh directly.
revoke all on function market.begin_refresh(text, interval, interval, interval) from public;
revoke all on function market.finish_refresh(text, boolean, text)               from public;
grant execute on function market.begin_refresh(text, interval, interval, interval) to service_role;
grant execute on function market.finish_refresh(text, boolean, text)               to service_role;

-- Reload PostgREST's schema cache so the new schema is visible without a restart.
notify pgrst, 'reload schema';
