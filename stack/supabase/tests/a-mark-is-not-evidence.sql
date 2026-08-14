-- Migration 55 clears performance marks our own price data contradicts — and must not clear more.
--
-- WHY THIS EXISTS AS A TEST. The migration set applies cleanly against an EMPTY database and that
-- proves nothing about this one: it is a data repair whose `update` matches ZERO rows when there
-- are no securities, so every predicate in it goes unexercised. Migration 38 reached production
-- exactly that way — green on an empty database, then violating a partial unique index against
-- rows only production had, and leaving the stack without `pending_prices` until the next pass.
--
-- So this seeds the production shape (securities negative-cached for performance, some with recent
-- price bars and some without) and asserts the three things the migration promises:
--
--   1. a mark contradicted by recent bars is CLEARED      the 2,548 real ones, e.g. MediaTek, ACS
--   2. a mark with no recent bars is KEPT                 the ~497 where it is plausible
--   3. it is ONE-SHOT                                     a second deploy must not re-clear
--
-- Point 3 is the one that matters most and is the easiest to lose. Migrations re-run on every
-- deploy, so an unguarded repair would clear this mark four times a day for ever — permanently
-- defeating the negative cache, which is the exact failure the flag exists to prevent. A
-- money-market line has a bar every day and one distinct close for ever: it earns its mark
-- honestly, and re-clearing it would re-ask a rate-limited provider for a known answer.
--
-- Run by the `migrations` job in quality.yml AFTER the application passes.

\set ON_ERROR_STOP on

begin;

insert into market.security (security_id, name, security_type_code, performance_missing_at) values
  -- Marked, and the provider is demonstrably answering: bars from yesterday.
  ('00000000-0000-0000-0000-0000000055a1', 'T55 Contradicted', 'equity', now() - interval '2 days'),
  -- Marked, and nothing has priced it in months: the mark stands.
  ('00000000-0000-0000-0000-0000000055a2', 'T55 Silent',       'equity', now() - interval '2 days'),
  -- Marked, with bars that are real but OLD — the five-day window is the whole point, so this
  -- must be treated like the silent one rather than the contradicted one.
  ('00000000-0000-0000-0000-0000000055a3', 'T55 Stale bars',   'equity', now() - interval '2 days'),
  -- Never marked. Must stay never-marked.
  ('00000000-0000-0000-0000-0000000055a4', 'T55 Unmarked',     'equity', null)
on conflict (security_id) do nothing;

insert into market.security_price (security_id, date, close) values
  ('00000000-0000-0000-0000-0000000055a1', current_date - 1, 10.0),
  ('00000000-0000-0000-0000-0000000055a1', current_date - 2, 10.5),
  ('00000000-0000-0000-0000-0000000055a3', current_date - 40, 7.25),
  ('00000000-0000-0000-0000-0000000055a4', current_date - 1, 3.0)
on conflict (security_id, date) do nothing;

-- The repair has already run for real rows by the time this test executes, so its one_shot key is
-- present and re-applying the file is a no-op. Clear the key to exercise the body against the rows
-- seeded above — this is inside a transaction that rolls back.
delete from market.one_shot where key = '55-clear-contradicted-performance-marks';

\i stack/supabase/migrations/55-a-mark-is-not-evidence.sql

do $$
declare
  bad text;
begin
  select string_agg(format('%s: performance_missing_at %s, expected %s',
                           s.name,
                           case when s.performance_missing_at is null then 'cleared' else 'set' end,
                           e.want), '; ')
    into bad
  from market.security s
  join (values
    ('00000000-0000-0000-0000-0000000055a1'::uuid, 'cleared'),
    ('00000000-0000-0000-0000-0000000055a2'::uuid, 'set'),
    ('00000000-0000-0000-0000-0000000055a3'::uuid, 'set'),
    ('00000000-0000-0000-0000-0000000055a4'::uuid, 'cleared')
  ) e(security_id, want) on e.security_id = s.security_id
  where (case when s.performance_missing_at is null then 'cleared' else 'set' end)
        is distinct from e.want;

  if bad is not null then
    raise exception 'migration 55 cleared the wrong marks: %', bad;
  end if;
  raise notice 'ok  a mark contradicted by recent bars is cleared, and only that mark';
end $$;

-- ONE-SHOT. Re-mark the contradicted security and apply the migration again, exactly as the next
-- deploy will. The ledger key is now present, so the body must not run and the mark must survive.
update market.security
   set performance_missing_at = now()
 where security_id = '00000000-0000-0000-0000-0000000055a1';

\i stack/supabase/migrations/55-a-mark-is-not-evidence.sql

do $$
begin
  if (select performance_missing_at from market.security
       where security_id = '00000000-0000-0000-0000-0000000055a1') is null then
    raise exception 'migration 55 re-ran on a second deploy — the one_shot guard is not holding, '
                    'so every redeploy would defeat the negative cache it is repairing';
  end if;
  raise notice 'ok  the repair is one-shot — a redeploy does not re-clear';
end $$;

rollback;
