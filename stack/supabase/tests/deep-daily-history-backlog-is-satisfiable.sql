-- THE DEEP-DAILY BACKLOG MUST EMPTY WHEN THE WORK IS DONE, AND NOT BEFORE.
--
-- This is the defect this codebase has hit FIVE times: a `pending_*` view that re-asks for ever
-- because doing the work does not remove the row. `pending_industry` re-fetched the same top-300
-- securities by fund weight for months while reporting `classified: 282, ok: true`;
-- `security-share-stats` reported `stats: 0, remaining: 11136` on eight consecutive runs. Both
-- looked like throughput.
--
-- `pending_daily_history` is unusual among the price backlogs and that is the whole reason for
-- this test. Every other one can ask "are there rows?" — but every security ALREADY has daily rows
-- (the ~400-day window `security-prices` maintains), so "has no daily bars" cannot express "has no
-- DEEP daily bars". The view leans entirely on `security.daily_history_from`, so if the resource
-- ever stops writing that column, or the view stops reading it, the backlog silently becomes
-- infinite — and the symptom would be a `written` in the millions with a `remaining` that never
-- moves, which reads as progress.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;

-- Three securities, one per state the view must distinguish.
insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-00000000d101','Deep Done','equity'),
  ('00000000-0000-0000-0000-00000000d102','Deep Wanted','equity'),
  ('00000000-0000-0000-0000-00000000d103','Deep Refused','equity')
on conflict (security_id) do nothing;

insert into market.security_identifier (kind_code, value, security_id) values
  ('ticker','DEEPDONE','00000000-0000-0000-0000-00000000d101'),
  ('ticker','DEEPWANT','00000000-0000-0000-0000-00000000d102'),
  ('ticker','DEEPREFU','00000000-0000-0000-0000-00000000d103')
on conflict (kind_code, value) do nothing;

-- ALL THREE GET RECENT DAILY BARS, which is the point: the 400-day window exists for every priced
-- security, so a view keyed on "has daily rows" would consider all three done. Only
-- `daily_history_from` separates them.
insert into market.security_price (security_id, date, close, grain)
select s, d::date, 100, 'daily'
  from (values ('00000000-0000-0000-0000-00000000d101'::uuid),
               ('00000000-0000-0000-0000-00000000d102'::uuid),
               ('00000000-0000-0000-0000-00000000d103'::uuid)) v(s),
       generate_series(current_date - 5, current_date, interval '1 day') d
on conflict do nothing;

-- d101 has been backfilled. d103 was asked and the provider had nothing (fresh negative cache).
update market.security set daily_history_from = date '1998-04-09'
 where security_id = '00000000-0000-0000-0000-00000000d101';
update market.security set daily_history_missing_at = now() - interval '2 days'
 where security_id = '00000000-0000-0000-0000-00000000d103';

do $$
declare done_n int; want_n int; refused_n int;
begin
  select count(*) into done_n    from market.pending_daily_history where symbol = 'DEEPDONE';
  select count(*) into want_n    from market.pending_daily_history where symbol = 'DEEPWANT';
  select count(*) into refused_n from market.pending_daily_history where symbol = 'DEEPREFU';

  if done_n <> 0 then
    raise exception 'pending_daily_history is UNSATISFIABLE: a security with daily_history_from '
                    'set is still queued (% rows). Doing the work must remove the row, or this '
                    'backfills the same head for ever while reporting millions of bars written.', done_n;
  end if;
  if want_n <> 1 then
    raise exception 'pending_daily_history dropped work: a security with recent bars but no deep '
                    'history appears % times, expected 1. Note it HAS daily rows — a view asking '
                    '"are there daily bars?" would wrongly consider it done.', want_n;
  end if;
  if refused_n <> 0 then
    raise exception 'pending_daily_history ignores its negative cache: a security marked 2 days '
                    'ago is queued again (% rows). Without the 30-day hold this re-asks a '
                    'rate-limited provider for a known answer.', refused_n;
  end if;
  raise notice '  ok  pending_daily_history: backfilled leaves, wanted stays, refused is held';
end $$;

-- AND THE HOLD MUST EXPIRE. A negative cache that never released would make one bad day permanent —
-- 30 days, not never, because a security the provider does not carry today may be carried later.
update market.security set daily_history_missing_at = now() - interval '31 days'
 where security_id = '00000000-0000-0000-0000-00000000d103';
do $$
declare n int;
begin
  select count(*) into n from market.pending_daily_history where symbol = 'DEEPREFU';
  if n <> 1 then
    raise exception 'an expired daily_history_missing_at did not return the security to the '
                    'backlog (% rows) — the negative cache is permanent, not a 30-day hold', n;
  end if;
  raise notice '  ok  the negative cache expires and the security is re-queued';
end $$;

rollback;
