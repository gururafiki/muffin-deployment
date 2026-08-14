-- Adding a venue must clear the marks set while it was missing — and only those.
--
-- WHY THIS EXISTS. Migration 63 added five venues so their securities could resolve a symbol, and
-- quoted the Taiwan lesson in its own comment: "a negative cache can memorise your own bug ... any
-- resolution fix must invalidate what the old behaviour poisoned." It then did not do that. The
-- sweep worked immediately, and the securities stayed symbol-less because `security-tickers` had
-- already recorded them unresolvable: Kuwait 38 of 40, Qatar 33 of 35, **Vietnam 57 of 57**.
-- `security-local-symbols` reported `remaining: 0, "no addressable securities pending"`.
--
-- The mark was honest about what happened — OpenFIGI answered and returned listings on venues this
-- pipeline did not know — and could not express that the answer depended on OUR catalogue, which
-- had just changed. Nothing failed; the fix simply had no effect, which is the hardest kind of
-- non-event to notice.
--
-- Three behaviours, and the last is what stops this becoming a blunt instrument:
--
--   1. a mark in an affected country is CLEARED    KW/QA/VN/AR
--   2. a mark ELSEWHERE is untouched               figi_missing_at is earned honestly almost
--                                                  everywhere, and a global clear would re-ask a
--                                                  rate-limited provider for answers we hold
--   3. it is ONE-SHOT                              or every deploy re-clears marks earned since

\set ON_ERROR_STOP on

begin;

insert into market.security (security_id, name, security_type_code, country_iso2,
                             figi_missing_at, local_symbol_missing_at) values
  ('00000000-0000-0000-0000-0000000064a1', 'T64 Kuwait',  'equity', 'KW', now() - interval '3 days', null),
  ('00000000-0000-0000-0000-0000000064a2', 'T64 Vietnam', 'equity', 'VN', now() - interval '3 days', now() - interval '3 days'),
  -- A country whose venue was NOT added. Its mark is earned and must survive.
  ('00000000-0000-0000-0000-0000000064a3', 'T64 Germany', 'equity', 'DE', now() - interval '3 days', null),
  -- Affected country, never marked. Must stay unmarked rather than being touched.
  ('00000000-0000-0000-0000-0000000064a4', 'T64 Qatar',   'equity', 'QA', null, null)
on conflict (security_id) do nothing;

delete from market.one_shot where key = '64-clear-marks-for-newly-swept-venues';

\i stack/supabase/migrations/64-a-new-venue-invalidates-its-marks.sql

do $$
declare
  bad text;
begin
  select string_agg(format('%s: figi %s, expected %s', s.name,
                           case when s.figi_missing_at is null then 'cleared' else 'set' end,
                           e.want), '; ')
    into bad
  from market.security s
  join (values
    ('00000000-0000-0000-0000-0000000064a1'::uuid, 'cleared'),
    ('00000000-0000-0000-0000-0000000064a2'::uuid, 'cleared'),
    ('00000000-0000-0000-0000-0000000064a3'::uuid, 'set'),
    ('00000000-0000-0000-0000-0000000064a4'::uuid, 'cleared')
  ) e(security_id, want) on e.security_id = s.security_id
  where (case when s.figi_missing_at is null then 'cleared' else 'set' end) is distinct from e.want;

  if bad is not null then
    raise exception 'migration 64 cleared the wrong marks: %', bad;
  end if;

  if (select local_symbol_missing_at from market.security
       where security_id = '00000000-0000-0000-0000-0000000064a2') is not null then
    raise exception 'local_symbol_missing_at was not cleared — both ISIN-keyed flags were set '
                    'under the old catalogue, so both have to go';
  end if;
  raise notice 'ok  marks in the newly-swept countries are cleared, and marks elsewhere are not';
end $$;

-- ONE-SHOT, in the form that actually drifts: a later edit makes the ledger insert
-- conflict-tolerant and the body silently re-runs on every deploy.
update market.security set figi_missing_at = now()
 where security_id = '00000000-0000-0000-0000-0000000064a1';

\i stack/supabase/migrations/64-a-new-venue-invalidates-its-marks.sql

do $$
begin
  if (select figi_missing_at from market.security
       where security_id = '00000000-0000-0000-0000-0000000064a1') is null then
    raise exception 'migration 64 re-ran on a second deploy — every redeploy would re-ask OpenFIGI '
                    'for answers already held';
  end if;
  raise notice 'ok  the repair is one-shot';
end $$;

rollback;
