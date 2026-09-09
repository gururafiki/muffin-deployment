-- THE INGEST LEDGER: what to ask next, what an answer meant, and what a killed run leaves behind.
--
-- This is the one deliberately custom piece of the ingestion rework, and it exists because no
-- orchestrator models per-ITEM state. Dagster owns runs, schedules, retries, checks and freshness,
-- and the rework uses it for all of them — but its only per-item primitive is partitions, bounded
-- at ~25,000 per asset and meant for time windows, while the work here is ~12,350 securities times
-- ~40 facets. So the queue is three tables and a handful of functions, and everything else is the
-- orchestrator's.
--
-- It replaces, facet by facet as each family migrates: 38 `pending_*` views, 21 `%_missing_at`
-- columns and 8 `*_fetched_at` cursors bolted onto `market.security`, `market.refresh_log`, and the
-- `backlog_negative_cache` / `symbol_cache_classification` pair that exists only to keep those
-- columns honest. Nothing is retired here — this migration is additive, and the edge function keeps
-- running everything until a family is cut over.
--
-- Design and every measurement behind it:
--   docs/superpowers/specs/2026-09-09-ingestion-rework-design.md (umbrella)

create schema if not exists ingest;

-- The serving schema the app will eventually read, so the UI is decoupled from the raw tables.
-- Created empty on purpose: a heavy view has twice been an app outage here, and the point of a
-- separate schema is that the thing the app reads can be changed without touching what writes.
create schema if not exists api;

-- ---------------------------------------------------------------------------------------------
-- Types. `create type` has no `if not exists`, and this file re-runs on every deploy.
-- ---------------------------------------------------------------------------------------------
do $$ begin
  create type ingest.task_status as enum ('due','leased','fresh','absent','backoff','disabled');
exception when duplicate_object then null; end $$;

-- THE FIVE THINGS A PROVIDER CAN TELL US, AND THE TWO WAYS WE CAN FAIL TO ASK. This enum is the
-- whole point of the ledger. A request that FAILED and a request that ANSWERED NOTHING are
-- different facts: conflating them one way recorded ~8,300 securities as permanently unanswerable
-- in an afternoon while every count read as progress, and conflating them the other way stalled
-- weight-ordered backlogs on their own head for weeks.
do $$ begin
  create type ingest.outcome as enum (
    'answered',           -- rows came back; the only outcome that clears a task
    'empty',              -- the provider answered and had nothing (openbb's 204 is this)
    'throttled',          -- the provider is refusing us; evidence about the PROVIDER, never a subject
    'dead_subject',       -- the provider named this subject as one it cannot serve
    'unsupported_venue',  -- the ROUTE does not cover this market, so a better symbol cannot help
    'transport',          -- we never got an answer; says nothing about the subject
    'parser_killed',      -- we got the document and could not read it inside our own limits
    'lease_expired'       -- the run died holding this task; written by reap(), never by a worker
  );
exception when duplicate_object then null; end $$;

-- WHAT A NEGATIVE CACHE IS KEYED ON, which is why `clear_symbol_caches` had to exist and why it was
-- wrong twice. A corrected SYMBOL invalidates a mark made under the old symbol; it says nothing
-- about a mark keyed on the ISIN or the CIK, and clearing those re-asks a rate-limited provider for
-- an answer we already hold.
do $$ begin
  create type ingest.key_kind as enum
    ('symbol','isin','figi','cik','corp_code','nse_symbol','fund','currency','none');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------------------------
-- Control tables.
-- ---------------------------------------------------------------------------------------------

-- One row per provider, holding the budget that Dagster pools cannot express. A pool serialises
-- RUNS; it has no notion of requests per second or per day. Alpha Vantage's 25-a-DAY is the case
-- that makes this a table rather than a constant.
create table if not exists ingest.provider_budget (
  provider_code  text primary key,
  rate_per_sec   numeric not null check (rate_per_sec > 0),
  burst          int not null default 1 check (burst >= 1),
  daily_quota    int check (daily_quota is null or daily_quota > 0),
  used_today     int not null default 0,
  quota_day      date not null default current_date,
  -- Set when a provider says it is refusing us. Nothing is marked while this is in the future;
  -- a throttle must cost a pause, never a population of dead securities.
  cooldown_until timestamptz,
  cooldown       interval not null default '15 minutes',
  -- A symbol known to work, used to prove the provider is healthy before any subject is blamed.
  control_subject text,
  enabled        boolean not null default true,
  note           text
);

-- A FACET IS A ROW, so adding one is data rather than a deploy. `population_sql` is the anti-join
-- that says who OWES this facet, and `retract_sql` is what an absence must remove — because a mark
-- excludes a security from the backlog, so the code that stops PRODUCING a number can never REMOVE
-- the stale one, and securities were served `1d = 0.00%` for four days that way.
create table if not exists ingest.facet (
  facet          text primary key,
  family         text not null,
  asset          text not null,               -- the Dagster asset / table it fills
  provider_code  text not null references ingest.provider_budget(provider_code),
  key_kind       ingest.key_kind not null,
  grain          text not null check (grain in ('security','filing','global')),
  ttl            interval not null,
  absent_ttl     interval not null default '30 days',
  backoff        interval not null default '1 hour',
  batch_size     int not null default 20 check (batch_size >= 1),
  page_size      int not null default 200 check (page_size >= 1),
  control_subject text,
  population_sql text not null,
  retract_sql    text,
  old_resource   text,                        -- provenance for the cutover, and the parity check
  old_missing_column text,
  enabled        boolean not null default false,
  note           text,
  -- A SYMBOL-KEYED FACET MUST SAY WHAT AN ABSENCE REMOVES. Without it a corrected symbol fixes the
  -- spelling and leaves the stale number in place, which is the defect above.
  constraint symbol_keyed_facets_retract check (key_kind <> 'symbol' or retract_sql is not null)
);

-- ---------------------------------------------------------------------------------------------
-- The queue.
-- ---------------------------------------------------------------------------------------------
create table if not exists ingest.task (
  facet          text not null references ingest.facet(facet) on delete cascade,
  subject        text not null,               -- security_id, or security_id:accession, or 'global'
  security_id    uuid references market.security(security_id) on delete cascade,
  status         ingest.task_status not null default 'due',
  priority       numeric not null default 0,  -- fund weight; an on-demand refresh jumps the queue
  -- ASSIGNED AT ENQUEUE AND NEVER RECOMPUTED. `pending_segments` ranked by a property of the
  -- SECURITY, so every filing of a company shared a sort key and the queue walked one filer's
  -- entire history — 440 filings belonging to 14 securities. The fix was a per-entity row_number,
  -- and the fix for the fix was that a window function computed over OUTSTANDING rows RENUMBERS as
  -- the queue drains, putting the same company straight back at the head. A stored round cannot.
  round          smallint not null default 1,
  next_due_at    timestamptz not null default now(),
  attempts       int not null default 0,
  last_asked_at    timestamptz,
  last_answered_at timestamptz,
  -- The exact key we asked under (BRK-B, US0378331005, 320193). A mark made under the wrong
  -- spelling is a statement about our typo, not about the company.
  asked_with     text,
  last_outcome   ingest.outcome,
  last_error     text,
  version        int not null default 0,      -- parser version, for a re-read without a deploy
  watermark      date,                        -- how far a history fetch has reached
  lease_id       uuid,
  lease_expires_at timestamptz,
  run_id         text,
  updated_at     timestamptz not null default now(),
  primary key (facet, subject)
);

create index if not exists task_claim_idx on ingest.task (facet, round, priority desc, subject)
  where status in ('due','backoff');
create index if not exists task_due_idx on ingest.task (facet, next_due_at)
  where status in ('due','backoff');
create index if not exists task_security_idx on ingest.task (security_id);
create index if not exists task_lease_idx on ingest.task (lease_expires_at) where status = 'leased';

-- APPEND-ONLY, AND THE REASON A KILLED RUN IS NO LONGER SILENT. `refresh_log` holds one row per
-- resource and overwrites it, so a resource dying on every firing keeps `started_at` fresh and
-- reads as just-started — which is how `security-cn-segments` died for two days without any check
-- noticing. A row is written when the attempt STARTS; `finished_at is null` past the timeout is
-- itself the alert.
create table if not exists ingest.attempt (
  attempt_id     bigserial primary key,
  run_id         text not null,
  facet          text not null,
  provider_code  text not null,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  duration_ms    int,
  http_status    int,
  subjects       int not null default 0,
  asked_with     text[],
  -- ASKED ALONE. `mark_absent` refuses without it, because a run-wide tally can only ever be a
  -- floor on the provider's health and is never evidence about one symbol.
  isolated       boolean not null default false,
  -- The provider answered for a known-good subject in this same attempt.
  control_answered boolean,
  outcome        ingest.outcome,
  error          text,
  answered       int not null default 0,
  empty          int not null default 0,
  dead           int not null default 0,
  rows_written   int not null default 0,
  rows_retracted int not null default 0
);
create index if not exists attempt_facet_idx on ingest.attempt (facet, started_at desc);
create index if not exists attempt_open_idx on ingest.attempt (started_at) where finished_at is null;

-- ---------------------------------------------------------------------------------------------
-- Functions. DROP-THEN-CREATE, not `create or replace`: replace PRESERVES the existing ACL, so a
-- grant in a re-run migration can only ever ADD a privilege and a line tightening permissions
-- applies cleanly while changing nothing. Measured on `aggregate_performance`.
-- ---------------------------------------------------------------------------------------------

-- Turn a leased task that nobody finished back into work, and close the attempt that was holding
-- it. THIS IS HOW A KILLED RUN LEAVES A RECORD: the worker cannot write its own epitaph, so the
-- next claim writes it.
drop function if exists ingest.reap();
create function ingest.reap() returns int
language plpgsql security definer set search_path = ingest, market, pg_catalog, pg_temp as $$
declare n int;
begin
  with expired as (
    update ingest.task
       set status = 'backoff',
           last_outcome = 'lease_expired',
           next_due_at = now() + (select backoff from ingest.facet f where f.facet = task.facet),
           lease_id = null, lease_expires_at = null, updated_at = now()
     where status = 'leased' and lease_expires_at < now()
     returning run_id, facet
  )
  select count(*) into n from expired;

  update ingest.attempt a
     set finished_at = now(), outcome = 'lease_expired',
         error = coalesce(a.error, 'the run holding this attempt died without finishing it')
   where a.finished_at is null and a.started_at < now() - interval '10 minutes';
  return n;
end $$;

-- Take a page. `for update skip locked` is what makes two workers safe, and the ORDER is what makes
-- the queue breadth-first: `round` first (the filing's depth into its own company's history), the
-- entity's importance second. Ordering by importance alone is depth-first and invisible — every
-- counter reads healthy while the rows being written are correct and simply the wrong rows first.
drop function if exists ingest.claim(text, int, interval, text);
create function ingest.claim(p_facet text, p_limit int, p_lease interval, p_run_id text)
returns setof ingest.task
language plpgsql security definer set search_path = ingest, market, pg_catalog, pg_temp as $$
declare v_lease uuid := gen_random_uuid();
begin
  perform ingest.reap();
  return query
  with picked as (
    select t.facet, t.subject
      from ingest.task t
     where t.facet = p_facet
       and t.status in ('due','backoff')
       and t.next_due_at <= now()
     order by t.round, t.priority desc, t.subject
     limit p_limit
       for update skip locked
  )
  update ingest.task t
     set status = 'leased', lease_id = v_lease, lease_expires_at = now() + p_lease,
         run_id = p_run_id, attempts = t.attempts + 1, last_asked_at = now(), updated_at = now()
    from picked p
   where t.facet = p.facet and t.subject = p.subject
  returning t.*;
end $$;

-- Record what an answer MEANT. Everything except a settled absence goes through here; `mark_absent`
-- is separate because it is the only one that can be wrong in a way that costs a month.
drop function if exists ingest.complete(text, text, ingest.outcome, text, date, text);
create function ingest.complete(
  p_facet text, p_subject text, p_outcome ingest.outcome,
  p_asked_with text default null, p_watermark date default null, p_error text default null
) returns void
language plpgsql security definer set search_path = ingest, market, pg_catalog, pg_temp as $$
declare f ingest.facet%rowtype;
begin
  select * into f from ingest.facet where facet = p_facet;
  if not found then raise exception 'unknown facet %', p_facet; end if;

  if p_outcome = 'answered' then
    update ingest.task
       set status = 'fresh', next_due_at = now() + f.ttl, last_answered_at = now(),
           last_outcome = p_outcome, last_error = null, asked_with = coalesce(p_asked_with, asked_with),
           watermark = coalesce(p_watermark, watermark),
           lease_id = null, lease_expires_at = null, updated_at = now()
     where facet = p_facet and subject = p_subject;

  elsif p_outcome in ('dead_subject','unsupported_venue') then
    raise exception
      'a settled absence goes through ingest.mark_absent(), which requires the attempt that proves it';

  else
    -- throttled / transport / empty / parser_killed: back off and mark NOTHING. An empty answer is
    -- only ever evidence about a subject once it has been asked ALONE with the provider proven
    -- healthy, and that proof lives in `ingest.attempt`.
    update ingest.task
       set status = 'backoff', next_due_at = now() + f.backoff,
           last_outcome = p_outcome, last_error = left(p_error, 500),
           asked_with = coalesce(p_asked_with, asked_with),
           lease_id = null, lease_expires_at = null, updated_at = now()
     where facet = p_facet and subject = p_subject;
  end if;
end $$;

-- THE ONLY PATH TO `absent`, AND IT REFUSES WITHOUT THE EVIDENCE. The isolation rule lived in a
-- comment at one call site and did not travel to the helper that later generalised the batching,
-- which is how a single outage negative-cached 1,369 answerable securities. Here it is a
-- precondition of the one function that can write the mark.
drop function if exists ingest.mark_absent(text, text, bigint, text);
create function ingest.mark_absent(
  p_facet text, p_subject text, p_attempt_id bigint, p_asked_with text default null
) returns void
language plpgsql security definer set search_path = ingest, market, pg_catalog, pg_temp as $$
declare f ingest.facet%rowtype; a ingest.attempt%rowtype;
begin
  select * into f from ingest.facet where facet = p_facet;
  if not found then raise exception 'unknown facet %', p_facet; end if;

  select * into a from ingest.attempt where attempt_id = p_attempt_id;
  if not found then raise exception 'no attempt % to justify marking % absent', p_attempt_id, p_subject; end if;
  if not a.isolated then
    raise exception
      'refusing to mark % absent: attempt % did not ask it ALONE, and a run-wide tally is never evidence about one subject',
      p_subject, p_attempt_id;
  end if;
  if a.control_answered is distinct from true then
    raise exception
      'refusing to mark % absent: attempt % did not prove the provider healthy with a control subject',
      p_subject, p_attempt_id;
  end if;

  -- MARKING MUST RETRACT. The mark excludes the subject from the backlog, so nothing else will ever
  -- remove the stale number it stops producing.
  if f.retract_sql is not null then
    execute f.retract_sql using p_subject;
    update ingest.attempt set rows_retracted = rows_retracted + 1 where attempt_id = p_attempt_id;
  end if;

  update ingest.task
     set status = 'absent', next_due_at = now() + f.absent_ttl,
         last_outcome = a.outcome, asked_with = coalesce(p_asked_with, asked_with),
         lease_id = null, lease_expires_at = null, updated_at = now()
   where facet = p_facet and subject = p_subject;
end $$;

-- A CORRECTED SYMBOL INVALIDATES ONLY THE SYMBOL-KEYED MARKS. `clear_symbol_caches` clears a
-- hand-written list of columns, and when a tenth arrived it was not added — locking 4,801 of 12,348
-- equities out of `pending_prices` with no error and `ok: true` throughout. Keyed on the facet's own
-- declared `key_kind`, that cannot happen: a new facet declares what it is keyed on or it is not a
-- facet.
drop function if exists ingest.requeue_symbol_keyed(uuid);
create function ingest.requeue_symbol_keyed(p_security_id uuid) returns int
language plpgsql security definer set search_path = ingest, market, pg_catalog, pg_temp as $$
declare n int;
begin
  with cleared as (
    update ingest.task t
       set status = 'due', next_due_at = now(), last_outcome = null, updated_at = now()
      from ingest.facet f
     where f.facet = t.facet
       and f.key_kind = 'symbol'
       and t.security_id = p_security_id
       and t.status = 'absent'
    returning 1
  ) select count(*) into n from cleared;
  return n;
end $$;

-- Bump a facet's parser version and every task behind it re-queues. No deploy, no hand-written
-- UPDATE, and it cannot be confused with a negative cache: a filed document is immutable, so what
-- changes is our reading of it.
drop function if exists ingest.requeue_version(text, int);
create function ingest.requeue_version(p_facet text, p_version int) returns int
language plpgsql security definer set search_path = ingest, market, pg_catalog, pg_temp as $$
declare n int;
begin
  with bumped as (
    update ingest.task
       set status = 'due', next_due_at = now(), version = p_version, updated_at = now()
     where facet = p_facet and version < p_version
    returning 1
  ) select count(*) into n from bumped;
  return n;
end $$;

-- Spend from a provider's daily quota, atomically. Returns false when the budget is gone or the
-- provider is in cooldown, so a caller stops rather than discovering it one 429 at a time.
drop function if exists ingest.spend(text, int);
create function ingest.spend(p_provider text, p_n int default 1) returns boolean
language plpgsql security definer set search_path = ingest, market, pg_catalog, pg_temp as $$
declare b ingest.provider_budget%rowtype;
begin
  select * into b from ingest.provider_budget where provider_code = p_provider for update;
  if not found then raise exception 'unknown provider %', p_provider; end if;
  if not b.enabled then return false; end if;
  if b.cooldown_until is not null and b.cooldown_until > now() then return false; end if;

  if b.quota_day < current_date then
    update ingest.provider_budget set used_today = 0, quota_day = current_date
     where provider_code = p_provider;
    b.used_today := 0;
  end if;

  if b.daily_quota is not null and b.used_today + p_n > b.daily_quota then return false; end if;

  update ingest.provider_budget set used_today = used_today + p_n where provider_code = p_provider;
  return true;
end $$;

-- ---------------------------------------------------------------------------------------------
-- The writer's role and its grants.
--
-- NOLOGIN here, exactly as `metrics_ro` is: the password is set by Ansible from a Docker secret, so
-- it never reaches a migration or a git history. `statement_timeout` is 120s and is deliberately a
-- THIRD limit distinct from anon's 3s and PostgREST's 8s — this role holds a direct connection, so
-- a derivation that cannot finish in a PostgREST RPC is no longer forced into pages.
-- ---------------------------------------------------------------------------------------------
do $$ begin
  create role ingest_rw nologin;
exception when duplicate_object then null; end $$;

alter role ingest_rw set statement_timeout = '120s';

grant usage on schema ingest, market, api to ingest_rw;
grant select, insert, update, delete on all tables in schema ingest to ingest_rw;
grant usage, select on all sequences in schema ingest to ingest_rw;
grant select, insert, update, delete on all tables in schema market to ingest_rw;
grant usage, select on all sequences in schema market to ingest_rw;
-- POSTGRES GRANTS EXECUTE TO **PUBLIC** BY DEFAULT, so a grant here is decorative until that is
-- revoked — measured on `aggregate_performance`, where every role could already execute a function
-- whose explicit grant read as the thing permitting it. These are SECURITY DEFINER and they write.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'ingest'
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to ingest_rw', f.sig);
  end loop;
end $$;

alter default privileges in schema ingest grant select, insert, update, delete on tables to ingest_rw;
alter default privileges in schema ingest grant usage, select on sequences to ingest_rw;

-- A TABLE ADDED BY A **LATER** MIGRATION WOULD NOT BE GRANTED UNTIL THE NEXT DEPLOY, because this
-- file runs before it. `security_price` shipped with no grant at all and was unreachable in
-- production while passing every migration test, since those run as superuser. Default privileges
-- close the window: they apply to whatever `postgres` creates from here on.
alter default privileges in schema market grant select, insert, update, delete on tables to ingest_rw;
alter default privileges in schema market grant usage, select on sequences to ingest_rw;

-- Grafana reads the ledger. Same role and same read-only posture as every other panel source.
grant usage on schema ingest to metrics_ro;
grant select on all tables in schema ingest to metrics_ro;
alter default privileges in schema ingest grant select on tables to metrics_ro;

-- The ledger is operational state, never app data: `anon` must not see it, exactly as
-- `refresh_log` and `ingest_run` are denied today.
revoke all on schema ingest from anon, authenticated;

-- The `dagster` DATABASE is created by Ansible, not here: `create database` cannot run inside a
-- transaction and every migration is applied `--single-transaction`.
