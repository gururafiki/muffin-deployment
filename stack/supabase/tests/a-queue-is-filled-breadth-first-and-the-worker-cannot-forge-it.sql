-- WHAT PUTS A ROW IN THE QUEUE, AND WHO IS ALLOWED TO CHANGE IT.
--
-- Two properties, and the fixture is built so the wrong implementation of each is DISTINGUISHABLE
-- rather than merely absent.
--
--   1. `round` is STORED AT ENQUEUE. The defect it exists for is subtle enough to have shipped
--      twice: `pending_segments` ordered by a property of the SECURITY, so one filer's whole
--      history drained before the next company was touched; the fix was a per-entity
--      `row_number()`; and the fix for THAT was that a window computed over the OUTSTANDING rows
--      RENUMBERS as the queue drains, so parsing a company's round 1 promotes its round 2 to round
--      1 and hands it the head again. Both versions look identical at t=0, which is why the
--      fixture DRAINS one filing and then asks what the others are numbered.
--
--   2. The worker cannot rewrite its own instructions. `mark_absent` refuses an absence without an
--      isolated attempt and a healthy control — but a role holding `update` on `ingest.task` can
--      set `status = 'absent'` itself and the refusal never runs, and a role holding `update` on
--      `ingest.facet` can put any statement into `retract_sql` for a SECURITY DEFINER function to
--      execute as postgres. Migration 207 revokes both. THESE ASSERTIONS RUN AS `ingest_rw` VIA
--      `set role`, because a migration test runs as SUPERUSER and would otherwise prove nothing
--      about a grant — the exact trap `every-table-is-reachable.sql` exists for.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZQ','Queueland','ZQ',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-0000000d7001','Q207 Deep Filer','equity','ZQ'),
  ('00000000-0000-0000-0000-0000000d7002','Q207 Shallow Filer','equity','ZQ')
  on conflict (security_id) do nothing;

insert into ingest.provider_budget (provider_code, rate_per_sec, control_subject, cooldown)
values ('t207-provider', 5, 'CONTROL', '20 minutes') on conflict (provider_code) do nothing;

-- The population. THE DEEP FILER OUTRANKS THE SHALLOW ONE ON PRIORITY, which is what makes the
-- test meaningful: ordering by importance alone is exactly the depth-first bug, so a queue that
-- reaches the shallow filer in its first two claims can only have done so via `round`.
create temporary table t207_pop (subject text, security_id uuid, priority numeric, entity_rank numeric);
insert into t207_pop values
  ('00000000-0000-0000-0000-0000000d7001:2025', '00000000-0000-0000-0000-0000000d7001', 9.0, 1),
  ('00000000-0000-0000-0000-0000000d7001:2024', '00000000-0000-0000-0000-0000000d7001', 9.0, 2),
  ('00000000-0000-0000-0000-0000000d7001:2023', '00000000-0000-0000-0000-0000000d7001', 9.0, 3),
  ('00000000-0000-0000-0000-0000000d7002:2025', '00000000-0000-0000-0000-0000000d7002', 1.0, 1);

insert into ingest.facet
  (facet, family, asset, provider_code, key_kind, grain, ttl, population_sql, enabled)
values
  ('t207-filings','test','t207_served','t207-provider','cik','filing','1 hour',
   'select subject, security_id, priority, entity_rank from t207_pop', true)
on conflict (facet) do nothing;

-- ---------------------------------------------------------------------------------------------
-- 1. Sync enqueues, and enqueues each subject once.
-- ---------------------------------------------------------------------------------------------
do $$
declare n int;
begin
  n := ingest.sync_population('t207-filings');
  if n <> 4 then raise exception 'first sync enqueued % subjects rather than 4', n; end if;

  -- AN ANTI-JOIN, NOT AN INSERT. A second sync over an unchanged population must add nothing;
  -- a backlog that re-enqueues is how the same work is done for ever while `written` reads as
  -- throughput.
  n := ingest.sync_population('t207-filings');
  if n <> 0 then raise exception 'the second sync enqueued % subjects over an unchanged population', n; end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Rounds are per entity, and the queue is breadth-first ACROSS entities.
-- ---------------------------------------------------------------------------------------------
do $$
declare r record; got text[];
begin
  select array_agg(subject order by subject) into got
    from ingest.task where facet = 't207-filings' and round = 1;
  if array_length(got, 1) <> 2 then
    raise exception 'round 1 holds % subjects rather than one per company: %', array_length(got,1), got;
  end if;

  for r in select subject, round from ingest.task where facet = 't207-filings' order by subject loop
    -- entity_rank 1,2,3 for the deep filer; the shallow one has a single filing at round 1.
    if r.subject like '%d7001:2025' and r.round <> 1 then raise exception '2025 is round %', r.round; end if;
    if r.subject like '%d7001:2024' and r.round <> 2 then raise exception '2024 is round %', r.round; end if;
    if r.subject like '%d7001:2023' and r.round <> 3 then raise exception '2023 is round %', r.round; end if;
    if r.subject like '%d7002:2025' and r.round <> 1 then raise exception 'shallow filer is round %', r.round; end if;
  end loop;
end $$;

-- A PAGE OF TWO MUST REACH BOTH COMPANIES. Ordered by priority alone it would take the deep
-- filer's 2025 and 2024 — nine times the weight — and never touch the other company.
do $$
declare seen int;
begin
  select count(distinct security_id) into seen
    from ingest.claim('t207-filings', 2, '5 minutes', 't207-run-1');
  if seen <> 2 then
    raise exception 'a page of two covered % companies rather than 2 — the queue is depth-first', seen;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 3. A STORED ROUND DOES NOT RENUMBER AS THE QUEUE DRAINS.
-- ---------------------------------------------------------------------------------------------
do $$
declare n int; r2024 smallint; r2023 smallint;
begin
  perform ingest.complete('t207-filings', '00000000-0000-0000-0000-0000000d7001:2025',
                          'answered'::ingest.outcome, 'CIK7001');

  n := ingest.sync_population('t207-filings');
  if n <> 0 then raise exception 'sync after a drain enqueued % subjects', n; end if;

  select round into r2024 from ingest.task
   where facet = 't207-filings' and subject = '00000000-0000-0000-0000-0000000d7001:2024';
  select round into r2023 from ingest.task
   where facet = 't207-filings' and subject = '00000000-0000-0000-0000-0000000d7001:2023';

  -- THIS IS THE ASSERTION THE WHOLE FIXTURE EXISTS FOR. Under a round computed over outstanding
  -- rows these would now read 1 and 2, putting this company straight back at the head of the queue
  -- while every counter still reported progress.
  if r2024 <> 2 or r2023 <> 3 then
    raise exception
      'rounds renumbered after a drain: 2024 is now %, 2023 is now % — a computed round hands the same company the head for ever',
      r2024, r2023;
  end if;
end $$;

-- A LATER FILING JOINS THE BACK OF ITS OWN COMPANY'S QUEUE, not the front.
do $$
declare n int; r smallint;
begin
  insert into t207_pop values
    ('00000000-0000-0000-0000-0000000d7001:2026', '00000000-0000-0000-0000-0000000d7001', 9.0, 0);
  n := ingest.sync_population('t207-filings');
  if n <> 1 then raise exception 'a newly published filing enqueued % rows rather than 1', n; end if;

  select round into r from ingest.task
   where facet = 't207-filings' and subject = '00000000-0000-0000-0000-0000000d7001:2026';
  -- entity_rank 0 makes it FIRST among the new rows, and it is still round 4: the company already
  -- holds three tasks. A filing arriving today must not preempt the two this company still owes,
  -- or a heavy filer is permanently at the head again.
  if r <> 4 then raise exception 'a new filing took round % rather than joining at 4', r; end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 4. A malformed population query names the facet.
-- ---------------------------------------------------------------------------------------------
do $$
declare ok boolean := false;
begin
  update ingest.facet set population_sql = 'select 1' where facet = 't207-filings';
  begin
    perform ingest.sync_population('t207-filings');
  exception when others then
    ok := position('t207-filings' in sqlerrm) > 0;
    if not ok then raise exception 'a bad population_sql failed without naming the facet: %', sqlerrm; end if;
  end;
  if not ok then raise exception 'a population_sql returning one column was accepted'; end if;
  update ingest.facet set population_sql = 'select subject, security_id, priority, entity_rank from t207_pop'
   where facet = 't207-filings';
end $$;

-- ---------------------------------------------------------------------------------------------
-- 5. A cooldown is a floor.
-- ---------------------------------------------------------------------------------------------
do $$
declare long timestamptz; short timestamptz;
begin
  long := ingest.cool_down('t207-provider', '1 hour');
  short := ingest.cool_down('t207-provider', '1 minute');
  if short < long then
    raise exception 'a second throttle SHORTENED the cooldown from % to % — a provider''s pause is a floor', long, short;
  end if;
  if ingest.spend('t207-provider', 1) then
    raise exception 'the budget allowed a call while the provider was in cooldown';
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 6. THE WORKER MAY NOT REWRITE ITS OWN INSTRUCTIONS, NOR FORGE AN ABSENCE.
--
-- As `ingest_rw`, not as postgres. A migration test runs as superuser, so every one of these would
-- pass for the wrong reason without `set role`.
-- ---------------------------------------------------------------------------------------------
do $$
declare denied boolean;
begin
  set local role ingest_rw;

  -- (a) The control table is not writable. With it writable, `retract_sql` is an arbitrary
  -- statement executed by a SECURITY DEFINER function as postgres.
  denied := false;
  begin
    update ingest.facet set retract_sql = 'select 1' where facet = 't207-filings';
  exception when insufficient_privilege then denied := true;
  end;
  if not denied then
    raise exception 'ingest_rw can write ingest.facet — retract_sql is executed as postgres, so that is a superuser escalation';
  end if;

  -- (b) The queue is not writable, which is what makes `mark_absent`'s refusal a RULE rather than
  -- a convention. 1,369 ordinary securities were once negative-cached in one afternoon.
  denied := false;
  begin
    update ingest.task set status = 'absent' where facet = 't207-filings';
  exception when insufficient_privilege then denied := true;
  end;
  if not denied then
    raise exception 'ingest_rw can set status directly, so the refusal to guess an absence can simply be walked around';
  end if;

  -- (c) The provider budget is not writable either: a quota it can edit is not a quota.
  denied := false;
  begin
    update ingest.provider_budget set daily_quota = 999999 where provider_code = 't207-provider';
  exception when insufficient_privilege then denied := true;
  end;
  if not denied then raise exception 'ingest_rw can rewrite its own provider budget'; end if;

  -- (d) But it MUST be able to append an attempt. That append is the whole reason a killed run
  -- stops being silent — `security-cn-segments` died on every firing for two days and
  -- `refresh_log`, holding one row per resource, read as just-started throughout.
  insert into ingest.attempt (run_id, facet, provider_code, subjects)
  values ('t207-run-2', 't207-filings', 't207-provider', 1);

  -- ...and to read the queue it is about to claim from.
  perform count(*) from ingest.task where facet = 't207-filings';

  reset role;
end $$;

rollback;

\echo 'ok: the queue fills breadth-first, a stored round survives a drain, and the worker cannot forge an absence or rewrite its instructions'
