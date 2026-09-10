-- A SKIPPED RUN IS NOT A SUCCESSFUL ONE, AND THE COLUMN SAYING SO WAS ALREADY THERE — IDEMPOTENT.
--
-- `market-refresh` answers `{"skipped": true, "reason": "fresh or in flight"}` with HTTP 200 when
-- the TTL has not elapsed or another invocation holds the lock. `recordRun` stores that as
-- `ok = true` — correctly, the invocation did succeed — **and it has recorded `skipped` on
-- `refresh_run` since migration 127.** Nothing read it. The resource-stalled alert asked
-- `max(finished_at) filter (where ok)`, so a resource that is permanently SKIPPING read as
-- succeeding every five minutes.
--
-- I FIRST WROTE THIS MIGRATION TO ADD THE COLUMN. It was already in the `create table` body, so
-- `add column if not exists` silently did nothing and my own behaviour test caught it — the
-- generated expression never applied and every row read `false`. Checking what the table already
-- CONTAINED would have been one query. Eighth instance of "the answer is already in a response you
-- fetch", this time about our own schema.
--
-- WHY IT MATTERS, measured 2026-09-01. A worker killed by the supervisor never calls
-- `finish_refresh` and holds the in-flight lock for ~2 minutes, so anything that pokes a dead
-- resource inside that window gets a skip. `security-segments` had been killed on every firing for
-- two days; the alert was correctly firing on a `last_ok` of 08-30; and three diagnostic calls,
-- all of which returned `skipped`, moved `last_ok` to the current minute.
-- **INVESTIGATING AN ALERT MUST NOT BE ABLE TO CLEAR IT.**

comment on column market.refresh_run.skipped is
  'True when the invocation returned `skipped: true` — the TTL had not elapsed, or another invocation held the in-flight lock. The call SUCCEEDED and did no work, so `ok` is true and THIS is what separates the two. Any "has this resource stopped" question must exclude skips, or a resource whose worker dies on every run reads as healthy from the wreckage of its own in-flight lock.';

-- The honest question, in one place rather than restated by every caller.
drop view if exists market.resource_health;
create view market.resource_health as
select
  r.resource,
  min(r.started_at)                                                   as first_seen,
  -- WORK, not merely a 200. This is the column every "has it stopped" check should read.
  max(r.finished_at) filter (where r.ok and not r.skipped)             as last_worked,
  -- Kept beside it deliberately: a large gap between the two IS the diagnosis — a resource whose
  -- worker is dying while its in-flight lock answers skips.
  max(r.finished_at) filter (where r.ok)                              as last_ok_including_skips,
  count(*) filter (where r.skipped and r.started_at > now() - interval '6 hours') as skips_6h,
  count(*) filter (where r.started_at > now() - interval '6 hours')    as runs_6h,
  -- HOW LONG THIS RESOURCE IS SUPPOSED TO BE QUIET FOR, from the TTL its own caller passed to
  -- `begin_refresh` (recorded on `refresh_log` in migration 002). A resource is not late until it
  -- is late BY ITS OWN SCHEDULE: `fund-holdings` has a 7-day TTL over quarterly SEC filings and is
  -- correctly silent for days, while `security-eps-history` on a short TTL and silent for 170h is
  -- genuinely stuck. Judging both against one 12-hour rule reported eight broken resources of
  -- which at least two were healthy — and an alert that cries wolf is how the real ones hide.
  (select extract(epoch from l.min_interval) / 3600.0
     from market.refresh_log l where l.resource = r.resource)          as ttl_hours,
  -- IS ANYTHING STILL ASKING FOR IT. A retired resource keeps its history for the 30 days this
  -- view looks back over, so it goes on looking stalled long after it was correctly switched off —
  -- `security-eps-history` was deleted from the cron by migration 138 when the nasdaq earnings
  -- calendar replaced it (one 3-day window returns 643 companies against alpha_vantage's 25 calls
  -- a DAY), and was still being reported as broken a week later. A resource nothing schedules
  -- cannot be late.
  exists (select 1 from market.cron_resource cr where cr.resource = r.resource) as scheduled
from market.refresh_run r
where r.started_at > now() - interval '30 days'
group by r.resource;

comment on view market.resource_health is
  'Per resource: when it last did WORK (a successful run that was not a skip), beside when it last returned ok at all. A large gap between the two is a resource whose worker is dying and whose in-flight wreckage is answering skips — which reads as healthy to anything counting `ok`. `refresh_log` cannot answer this: it holds one row per resource, overwritten every run, so a resource dying on a five-minute cron always looks just-started.';

grant select on market.resource_health to anon, authenticated, service_role;

notify pgrst, 'reload schema';
