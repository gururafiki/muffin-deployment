-- Migration 57 clears the statement marks set during the throttle window, and stops at the cutoff.
--
-- WHY THIS EXISTS AS A TEST. Like migration 55, this is a data repair whose `update` matches zero
-- rows on an empty database, so applying the migration set proves nothing about it. The behaviour
-- that matters is entirely in the CUTOFF: a repair that clears everything would wipe marks earned
-- honestly after the gates landed, and a repair that clears nothing leaves 2,445 blue chips
-- excluded for 30 days. Neither failure is visible in a count.

\set ON_ERROR_STOP on

begin;

insert into market.security (security_id, name, security_type_code, statements_missing_at) values
  -- Inside the throttle window: 1,032 marks in this one hour, against a ~15/hour steady state.
  ('00000000-0000-0000-0000-0000000057a1', 'T57 Burst',      'equity', timestamptz '2026-08-12 15:30:00+00'),
  -- The other burst, two days earlier.
  ('00000000-0000-0000-0000-0000000057a2', 'T57 Burst two',  'equity', timestamptz '2026-08-11 18:40:00+00'),
  -- AFTER the gates landed. Earned honestly, and must survive: this is the half that makes the
  -- repair a repair rather than a reset.
  ('00000000-0000-0000-0000-0000000057a3', 'T57 Post-fix',   'equity', timestamptz '2026-08-13 20:00:00+00'),
  -- Never marked.
  ('00000000-0000-0000-0000-0000000057a4', 'T57 Unmarked',   'equity', null)
on conflict (security_id) do nothing;

delete from market.one_shot where key = '57-clear-throttle-burst-statement-marks';

\i stack/supabase/migrations/057-a-burst-is-a-provider-event.sql

do $$
declare
  bad text;
begin
  select string_agg(format('%s: %s, expected %s', s.name,
                           case when s.statements_missing_at is null then 'cleared' else 'kept' end,
                           e.want), '; ')
    into bad
  from market.security s
  join (values
    ('00000000-0000-0000-0000-0000000057a1'::uuid, 'cleared'),
    ('00000000-0000-0000-0000-0000000057a2'::uuid, 'cleared'),
    ('00000000-0000-0000-0000-0000000057a3'::uuid, 'kept'),
    ('00000000-0000-0000-0000-0000000057a4'::uuid, 'cleared')
  ) e(security_id, want) on e.security_id = s.security_id
  where (case when s.statements_missing_at is null then 'cleared' else 'kept' end)
        is distinct from e.want;

  if bad is not null then
    raise exception 'migration 57 did not respect the cutoff: %', bad;
  end if;
  raise notice 'ok  the throttle window is cleared and marks earned after the fix survive';
end $$;

-- ONE-SHOT, in the form that actually drifts: a later edit adds `on conflict do nothing` to the
-- ledger insert to make the file "safe to re-run", and the body then re-clears on every deploy.
update market.security
   set statements_missing_at = timestamptz '2026-08-12 15:30:00+00'
 where security_id = '00000000-0000-0000-0000-0000000057a1';

\i stack/supabase/migrations/057-a-burst-is-a-provider-event.sql

do $$
begin
  if (select statements_missing_at from market.security
       where security_id = '00000000-0000-0000-0000-0000000057a1') is null then
    raise exception 'migration 57 re-ran on a second deploy — every redeploy would re-clear the '
                    'cache it is repairing, which is the failure the one_shot ledger exists to stop';
  end if;
  raise notice 'ok  the repair is one-shot — a redeploy does not re-clear';
end $$;

rollback;
