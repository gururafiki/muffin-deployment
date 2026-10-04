-- The ledger's live absences become `identifier_probe` misses, once, and nothing else does.
--
-- WHY THIS EXISTS AS A TEST. The migration is a data repair: on an empty ledger its insert matches
-- nothing, so applying the migration set proves nothing about it. What matters is which rows it
-- carries. A `backoff` carried as a miss marks a throttled symbol dead; an expired mark carried
-- re-sentences a symbol that is due; `now()` as the observation restarts every sentence; and a
-- re-run after the lane has answered re-marks a live symbol. Each fixture row makes one of those
-- rules the only thing deciding it.

\set ON_ERROR_STOP on

begin;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-00000003a001', 'T3A Live absence',     'equity'),
  ('00000000-0000-0000-0000-00000003a002', 'T3A Expired absence',  'equity'),
  ('00000000-0000-0000-0000-00000003a003', 'T3A Backoff',          'equity'),
  ('00000000-0000-0000-0000-00000003a004', 'T3A Already observed', 'equity'),
  ('00000000-0000-0000-0000-00000003a005', 'T3A Fresh',            'equity'),
  ('00000000-0000-0000-0000-00000003a006', 'T3A No symbol asked',  'equity'),
  ('00000000-0000-0000-0000-00000003a007', 'T3A Other facet',      'equity')
on conflict (security_id) do nothing;

-- A second facet, so that "only the price lane's marks" is a rule the fixture can break. The
-- ledger never had another symbol-keyed facet in production, which is exactly why nothing else
-- would notice the filter going.
insert into ingest.provider_budget (provider_code, rate_per_sec, control_subject)
  values ('t3a-provider', 1.0, 'XONE') on conflict (provider_code) do nothing;
insert into ingest.facet
  (facet, family, asset, provider_code, key_kind, grain, ttl, absent_ttl,
   population_sql, retract_sql, enabled)
values
  ('t3a-other', 'test', 't3a_asset', 't3a-provider', 'symbol', 'security',
   interval '1 day', interval '30 days',
   'select security_id::text as subject, security_id, 0::numeric as priority,'
   ' 1::numeric as entity_rank from market.security where false',
   'select 1', true)
  on conflict (facet) do nothing;

insert into ingest.task (facet, subject, security_id, status, next_due_at, asked_with, last_asked_at)
values
  -- Carried: unexpired, asked with a symbol.
  ('prices', '00000000-0000-0000-0000-00000003a001', '00000000-0000-0000-0000-00000003a001',
   'absent', now() + interval '21 days',
   'DEAD1', now() - interval '9 days'),
  -- Not carried: its thirty days are over, so the lane must ask it again.
  ('prices', '00000000-0000-0000-0000-00000003a002', '00000000-0000-0000-0000-00000003a002',
   'absent', now() - interval '1 day', 'DEAD2', now() - interval '31 days'),
  -- Not carried: a throttle or transport outcome says nothing about the symbol.
  ('prices', '00000000-0000-0000-0000-00000003a003', '00000000-0000-0000-0000-00000003a003',
   'backoff', now() + interval '1 hour', 'THROTTLED', now()),
  -- Carried in principle, but the lane has already observed it: its own row must win.
  ('prices', '00000000-0000-0000-0000-00000003a004', '00000000-0000-0000-0000-00000003a004',
   'absent', now() + interval '20 days', 'OLD4', now() - interval '10 days'),
  -- Not carried: answered.
  ('prices', '00000000-0000-0000-0000-00000003a005', '00000000-0000-0000-0000-00000003a005',
   'fresh', now() + interval '1 day', 'LIVE5', now()),
  -- Not carried: no symbol to match the miss against.
  ('prices', '00000000-0000-0000-0000-00000003a006', '00000000-0000-0000-0000-00000003a006',
   'absent', now() + interval '15 days', null, now() - interval '15 days'),
  -- Not carried: another facet's absence says nothing about the price provider.
  ('t3a-other', '00000000-0000-0000-0000-00000003a007', '00000000-0000-0000-0000-00000003a007',
   'absent', now() + interval '25 days', 'OTHER7', now() - interval '5 days');

insert into market.identifier_probe (security_id, scheme, provider, asked_with, value, outcome, observed_at)
values ('00000000-0000-0000-0000-00000003a004', 'symbol', 'yfinance', 'NEW4', 'NEW4', 'hit',
        now() - interval '1 hour');

delete from market.one_shot where key = 'ledger-absences-to-probes-2026-10-04';

\i stack/supabase/migrations/20261004160000_the_ledger_s_absences_become_observations.sql

do $$
declare
  got text;
  due timestamptz;
  seen timestamptz;
begin
  select string_agg(s.name || ':' || p.outcome || ':' || coalesce(p.asked_with, '-'), ', ' order by s.name)
    into got
    from market.identifier_probe p
    join market.security s using (security_id)
   where p.security_id::text like '00000000-0000-0000-0000-00000003a%'
     and p.scheme = 'symbol' and p.provider = 'yfinance';

  if got is distinct from 'T3A Already observed:hit:NEW4, T3A Live absence:miss:DEAD1' then
    raise exception 'carried the wrong rows: %, expected only the live absence, with the '
                    'lane''s own observation untouched', got;
  end if;

  select t.next_due_at, p.observed_at into due, seen
    from ingest.task t
    join market.identifier_probe p on p.security_id = t.security_id
   where t.security_id = '00000000-0000-0000-0000-00000003a001'
     and p.scheme = 'symbol' and p.provider = 'yfinance';
  if seen + interval '30 days' <> due then
    raise exception 'the carried miss expires at %, the ledger said %: its sentence was restarted',
                    seen + interval '30 days', due;
  end if;

  if (select value from market.identifier_probe
       where security_id = '00000000-0000-0000-0000-00000003a001'
         and scheme = 'symbol' and provider = 'yfinance') is not null then
    raise exception 'a miss carried a value; the lane writes none';
  end if;
  raise notice 'ok  only the live absence is carried, and it expires when the ledger said';
end $$;

-- ONE-SHOT. Every deploy re-runs this file, and the body must not run again. Removing the carried
-- row is what makes a second run visible: with the guard gone, the insert would put it back. (A
-- symbol the lane has since found alive is protected twice over, by the guard and by DO NOTHING,
-- which is why this case deletes rather than updates.)
delete from market.identifier_probe
 where security_id = '00000000-0000-0000-0000-00000003a001'
   and scheme = 'symbol' and provider = 'yfinance';

\i stack/supabase/migrations/20261004160000_the_ledger_s_absences_become_observations.sql

do $$
begin
  if exists (select 1 from market.identifier_probe
              where security_id = '00000000-0000-0000-0000-00000003a001'
                and scheme = 'symbol' and provider = 'yfinance') then
    raise exception 'the carry re-ran on a second deploy and re-marked a symbol';
  end if;
  raise notice 'ok  the carry is one-shot';
end $$;

rollback;
