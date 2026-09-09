-- THE LEDGER'S FOUR REFUSALS, each of which is a defect this pipeline has actually had.
--
-- The fixture is built so the candidate rules DISAGREE. A page of ONE over three tasks is
-- arithmetically unable to reach the third if the claim does not advance; a facet keyed on the ISIN
-- sits beside one keyed on the symbol so "requeue everything" and "requeue the symbol-keyed" are
-- distinguishable; and the attempt that justifies a mark is present in three variants — not
-- isolated, isolated with no control, and isolated with a control — so the two preconditions can be
-- told apart from each other rather than only from success.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZL','Ledgerland','ZL',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-0000000d6001','L206 One','equity','ZL'),
  ('00000000-0000-0000-0000-0000000d6002','L206 Two','equity','ZL'),
  ('00000000-0000-0000-0000-0000000d6003','L206 Three','equity','ZL')
  on conflict (security_id) do nothing;

insert into ingest.provider_budget (provider_code, rate_per_sec, daily_quota, control_subject)
values ('t206-provider', 2, 25, 'CONTROL') on conflict (provider_code) do nothing;

-- A symbol-keyed facet MUST declare what an absence retracts; the constraint enforces it, and the
-- retraction here is observable so the test can prove it ran.
create table if not exists ingest.t206_served (subject text primary key);
insert into ingest.facet (facet, family, asset, provider_code, key_kind, grain, ttl, retract_sql, enabled)
values
  ('t206-symbol','test','t206_served','t206-provider','symbol','security','1 hour',
   'delete from ingest.t206_served where subject = $1', true),
  ('t206-isin','test','t206_served','t206-provider','isin','security','1 hour', null, true)
  on conflict (facet) do nothing;

insert into ingest.task (facet, subject, security_id, round, priority) values
  ('t206-symbol','00000000-0000-0000-0000-0000000d6001','00000000-0000-0000-0000-0000000d6001',1,10),
  ('t206-symbol','00000000-0000-0000-0000-0000000d6002','00000000-0000-0000-0000-0000000d6002',1, 5),
  ('t206-symbol','00000000-0000-0000-0000-0000000d6003','00000000-0000-0000-0000-0000000d6003',1, 1)
  on conflict do nothing;

do $$
declare
  seen text[] := '{}';
  t ingest.task%rowtype;
  a_plain bigint; a_iso bigint; a_good bigint;
  n int;
begin
  -- 1. A PAGE OF ONE, THREE TIMES, MUST REACH THREE DIFFERENT SUBJECTS.
  --    A claim that does not lease returns the same head for ever while `written` reads as
  --    throughput — this repo's most-repeated defect.
  for i in 1..3 loop
    for t in select * from ingest.claim('t206-symbol', 1, interval '5 minutes', 'run-'||i) loop
      seen := seen || t.subject;
    end loop;
  end loop;
  if array_length(seen,1) is distinct from 3 or (select count(distinct x) from unnest(seen) x) <> 3 then
    raise exception 'a page of one over three tasks reached % subjects (%) rather than three',
      (select count(distinct x) from unnest(seen) x), seen;
  end if;

  -- 2. A LEASED TASK IS NOT RE-CLAIMED while its lease holds.
  if exists (select 1 from ingest.claim('t206-symbol', 5, interval '5 minutes', 'run-x')) then
    raise exception 'a leased task was claimed again; two workers would do the same work';
  end if;

  -- 3. AN EXPIRED LEASE RETURNS THE WORK **AND CLOSES THE ATTEMPT**, which is how a killed run
  --    stops being silent. `refresh_log` could not do this: one row per resource, overwritten.
  insert into ingest.attempt (run_id, facet, provider_code, started_at, subjects)
  values ('run-dead','t206-symbol','t206-provider', now() - interval '20 minutes', 1)
  returning attempt_id into a_plain;
  update ingest.task set lease_expires_at = now() - interval '1 minute'
   where facet = 't206-symbol' and status = 'leased';
  perform ingest.reap();
  if exists (select 1 from ingest.task where facet='t206-symbol' and status='leased') then
    raise exception 'reap left a task leased past its expiry';
  end if;
  if (select finished_at from ingest.attempt where attempt_id = a_plain) is null then
    raise exception 'reap left the dead run''s attempt open, so nothing records that it died';
  end if;

  -- 4. `complete` MUST REFUSE TO SETTLE AN ABSENCE, because the evidence for one lives in the
  --    attempt and not in the caller's opinion.
  begin
    perform ingest.complete('t206-symbol','00000000-0000-0000-0000-0000000d6001','dead_subject');
    raise exception 'complete() settled an absence without an attempt to justify it';
  exception when others then
    if sqlerrm not like '%mark_absent%' then raise; end if;
  end;

  -- 5. `mark_absent` REFUSES AN ATTEMPT THAT DID NOT ASK THE SUBJECT ALONE.
  --    A run-wide tally is only ever a floor on the provider's health. Believing it once recorded
  --    1,369 answerable securities as permanently dead.
  insert into ingest.attempt (run_id, facet, provider_code, subjects, isolated, control_answered, outcome)
  values ('run-1','t206-symbol','t206-provider', 40, false, true, 'empty') returning attempt_id into a_iso;
  begin
    perform ingest.mark_absent('t206-symbol','00000000-0000-0000-0000-0000000d6001', a_iso);
    raise exception 'a subject was marked absent on an attempt that asked 40 at once';
  exception when others then
    if sqlerrm not like '%ALONE%' then raise; end if;
  end;

  -- 6. AND IT REFUSES AN ISOLATED ATTEMPT THAT NEVER PROVED THE PROVIDER HEALTHY.
  --    yfinance under throttle answers 200-with-no-rows, so "asked alone and got nothing" is not
  --    enough on its own — every outage rule here was blind to exactly that.
  insert into ingest.attempt (run_id, facet, provider_code, subjects, isolated, control_answered, outcome)
  values ('run-2','t206-symbol','t206-provider', 1, true, null, 'empty') returning attempt_id into a_good;
  begin
    perform ingest.mark_absent('t206-symbol','00000000-0000-0000-0000-0000000d6001', a_good);
    raise exception 'a subject was marked absent without a control proving the provider was up';
  exception when others then
    if sqlerrm not like '%control%' then raise; end if;
  end;

  -- 7. WITH BOTH, IT MARKS **AND RETRACTS**. A mark excludes the subject from the backlog, so if it
  --    does not remove the stale value nothing ever will — securities served `1d = 0.00%` for four
  --    days that way.
  insert into ingest.t206_served (subject) values ('00000000-0000-0000-0000-0000000d6001')
    on conflict do nothing;
  insert into ingest.attempt (run_id, facet, provider_code, subjects, isolated, control_answered, outcome)
  values ('run-3','t206-symbol','t206-provider', 1, true, true, 'dead_subject') returning attempt_id into a_good;
  perform ingest.mark_absent('t206-symbol','00000000-0000-0000-0000-0000000d6001', a_good);
  if (select status from ingest.task where facet='t206-symbol' and subject='00000000-0000-0000-0000-0000000d6001') <> 'absent' then
    raise exception 'the subject was not marked absent when both preconditions held';
  end if;
  if exists (select 1 from ingest.t206_served where subject='00000000-0000-0000-0000-0000000d6001') then
    raise exception 'the mark did not retract the stale row it stops producing';
  end if;

  -- 8. A CORRECTED SYMBOL REQUEUES THE SYMBOL-KEYED FACET AND NOTHING ELSE.
  --    An ISIN-keyed mark says nothing about a spelling, and clearing it re-asks a rate-limited
  --    provider for an answer already held.
  insert into ingest.task (facet, subject, security_id, status, next_due_at)
  values ('t206-isin','00000000-0000-0000-0000-0000000d6001','00000000-0000-0000-0000-0000000d6001',
          'absent', now() + interval '30 days')
  on conflict (facet, subject) do update set status = 'absent';
  select ingest.requeue_symbol_keyed('00000000-0000-0000-0000-0000000d6001') into n;
  if n <> 1 then
    raise exception 'requeue touched % tasks rather than the one symbol-keyed task', n;
  end if;
  if (select status from ingest.task where facet='t206-isin') <> 'absent' then
    raise exception 'requeue cleared an ISIN-keyed mark, which a new symbol is no evidence about';
  end if;

  -- 9. A DAILY QUOTA IS SPENT, NOT HOPED FOR. Alpha Vantage allows 25 calls a DAY, and a resource
  --    that discovers that one 429 at a time burns the budget learning it.
  for i in 1..25 loop
    if not ingest.spend('t206-provider', 1) then
      raise exception 'the quota refused call % of its 25', i;
    end if;
  end loop;
  if ingest.spend('t206-provider', 1) then
    raise exception 'the 26th call was allowed against a 25-a-day quota';
  end if;
end $$;

rollback;

\echo 'ok: the ledger advances, records a death, refuses to guess an absence, retracts, and spends a quota'
