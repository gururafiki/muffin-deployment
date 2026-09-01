-- A SKIPPED RUN IS A SUCCESSFUL INVOCATION THAT DID NO WORK.
--
-- WHY. `market-refresh` answers `{"skipped": true, "reason": "fresh or in flight"}` with HTTP 200
-- when the TTL has not elapsed or another invocation holds the lock, and `recordRun` stores that as
-- `ok = true` — correctly, because the call did succeed. The resource-stalled alert then asked
-- `max(finished_at) filter (where ok)`, so a resource that is permanently SKIPPING read as
-- succeeding every five minutes.
--
-- It is not hypothetical. A worker killed by the supervisor never calls `finish_refresh` and holds
-- the in-flight lock for ~2 minutes, so anything that pokes a dead resource inside that window gets
-- a skip. Measured 2026-09-01: `security-segments` had been killed on every firing for two days,
-- the alert was correctly firing on a `last_ok` of 08-30, and three diagnostic calls — all of which
-- returned `skipped` — moved `last_ok` to the current minute. INVESTIGATING AN ALERT MUST NOT BE
-- ABLE TO CLEAR IT.
--
-- THE FIXTURE MAKES THE TWO RULES DISAGREE: the last run that did WORK is old, and the newest run
-- is a fresh skip. Under `filter (where ok)` the resource looks alive; under
-- `filter (where ok and not skipped)` it is two days stale.

\set ON_ERROR_STOP on

begin;

-- `skipped` IS A REAL COLUMN THE APPLICATION WRITES, not one generated from `report` — it has
-- been on this table since migration 127. The fixture sets it exactly as `recordRun` does, because
-- a fixture that only wrote `report` would leave it at its `false` default and assert nothing.
-- (That is how the first version of this test failed, which is also how the redundant generated
-- column I had written was caught.)
insert into market.refresh_run (resource, started_at, finished_at, ok, skipped, report) values
  -- Real work, two days ago.
  ('t167-dying', now() - interval '50 hours', now() - interval '50 hours', true, false,
   '{"written": 400, "remaining": 900}'::jsonb),
  -- Then nothing but skips, the most recent of them a minute old.
  ('t167-dying', now() - interval '20 minutes', now() - interval '20 minutes', true, true,
   '{"skipped": true, "reason": "fresh or in flight"}'::jsonb),
  ('t167-dying', now() - interval '1 minute',  now() - interval '1 minute',  true, true,
   '{"skipped": true, "reason": "fresh or in flight"}'::jsonb),
  -- A healthy resource, for contrast.
  ('t167-healthy', now() - interval '30 hours', now() - interval '30 hours', true, false,
   '{"written": 10, "remaining": 5}'::jsonb),
  ('t167-healthy', now() - interval '10 minutes', now() - interval '10 minutes', true, false,
   '{"written": 12, "remaining": 0}'::jsonb);

do $$
declare worked timestamptz; ok_any timestamptz; sk int; rn int;
begin
  select last_worked, last_ok_including_skips, skips_6h, runs_6h
    into worked, ok_any, sk, rn
    from market.resource_health where resource = 't167-dying';

  if worked is null then
    raise exception 'the dying resource has no last_worked at all — its one real run must still count';
  end if;
  if extract(epoch from (now() - worked)) / 3600 < 40 then
    raise exception 'last_worked is %h old; it must reflect the run that did WORK (50h), not the skips that followed', round(extract(epoch from (now() - worked)) / 3600);
  end if;
  if extract(epoch from (now() - ok_any)) / 3600 > 1 then
    raise exception 'last_ok_including_skips is stale — the fixture is not exercising the difference, so the two rules cannot be told apart';
  end if;

  -- THE WHOLE POINT: counting `ok` says a minute, counting work says two days.
  if worked >= ok_any then
    raise exception 'last_worked is not older than last_ok_including_skips — a skip is being counted as work, and a resource whose worker dies reads as healthy from its own wreckage';
  end if;

  if sk <> 2 or rn <> 2 then
    raise exception 'skips_6h=% runs_6h=% — both recent runs are skips, and the check that names "dying, answering skips" depends on those agreeing', sk, rn;
  end if;

  -- The healthy one must NOT be flagged by the same reading.
  select last_worked into worked from market.resource_health where resource = 't167-healthy';
  if extract(epoch from (now() - worked)) / 3600 > 1 then
    raise exception 'a resource that did work ten minutes ago reads as %h stale — the rule fires on the innocent shape', round(extract(epoch from (now() - worked)) / 3600);
  end if;
end $$;

rollback;

\echo 'ok: a skip is recorded as such, and last_worked ignores it'
