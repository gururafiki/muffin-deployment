-- A SKIPPED CALL MUST STILL RECORD ITS TTL, BECAUSE THE SKIPPING ONES ARE WHY THE TTL EXISTS.
--
-- `refresh_log.min_interval` lets the stalled-resource alert judge a resource by its OWN schedule —
-- `fund-holdings` has a 7-day TTL over quarterly SEC filings and is correctly silent for a week,
-- while a flat 12-hour rule flags it beside resources that have genuinely stopped.
--
-- The write started out AFTER both of `begin_refresh`'s early returns, so a resource that skipped
-- never recorded anything. Measured one deploy after shipping it: 18 of 46 resources had a TTL, all
-- of them ones that had actually claimed, and the alert went on flagging eight resources against the
-- 12-hour fallback. A self-defeating fix — the evidence was collected only where it was not needed.
--
-- THE FIXTURE IS THE PRODUCTION SHAPE: a row that already exists, is FRESH (so the call skips), and
-- has no TTL recorded. If the write ever moves back below the skip check, this fails and the
-- claiming case below still passes — which is exactly how the defect hid.

\set ON_ERROR_STOP on

begin;

-- Fresh and successful, so `begin_refresh` must SKIP it. No TTL recorded yet.
insert into market.refresh_log (resource, started_at, finished_at, ok, error, min_interval)
values ('t171-skipper', now() - interval '1 minute', now() - interval '1 minute', true, null, null)
on conflict (resource) do update
   set started_at = excluded.started_at, finished_at = excluded.finished_at,
       ok = excluded.ok, min_interval = null;

do $$
declare
  claimed boolean;
  ttl     interval;
begin
  -- 1. THE SKIP PATH. A 30-day TTL against a run that finished a minute ago: it must decline the
  --    claim AND still record what it was asked for.
  select market.begin_refresh('t171-skipper', interval '30 days') into claimed;
  if claimed then
    raise exception 'a resource that finished a minute ago must not be claimed again';
  end if;

  select min_interval into ttl from market.refresh_log where resource = 't171-skipper';
  if ttl is distinct from interval '30 days' then
    raise exception 'a SKIPPED call must still record its TTL: got %, expected 30 days', ttl;
  end if;

  -- 2. THE CLAIM PATH still works — this is the half that was never broken, and keeping it here is
  --    what stops a "fix" that only records on a skip from passing.
  delete from market.refresh_log where resource = 't171-claimer';
  select market.begin_refresh('t171-claimer', interval '10 minutes') into claimed;
  if not claimed then
    raise exception 'a resource with no prior run must be claimable';
  end if;
  select min_interval into ttl from market.refresh_log where resource = 't171-claimer';
  if ttl is distinct from interval '10 minutes' then
    raise exception 'a CLAIMED call must record its TTL: got %, expected 10 minutes', ttl;
  end if;

  -- 3. AND A CHANGED TTL IS PICKED UP. The value follows the caller, so re-tuning a resource's TTL
  --    in `EXTRA_TTL_MINUTES` must reach the alert without anyone editing a table.
  perform market.begin_refresh('t171-skipper', interval '7 days');
  select min_interval into ttl from market.refresh_log where resource = 't171-skipper';
  if ttl is distinct from interval '7 days' then
    raise exception 'a changed TTL must be recorded even on a skip: got %', ttl;
  end if;

  raise notice 'ok  a skip records its TTL (skip, claim and re-tune all covered)';
end $$;

rollback;
