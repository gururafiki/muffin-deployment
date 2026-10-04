-- `market.mark_venue_absence` marks a directory line only on the evidence of a finished walk able
-- to see it, and refuses a window where most lines look unseen. Migration 20261004120000.
--
-- The fixture is one venue, T5V, whose common-stock query is CAPPED at FIGI BBGT5V0500 and has an
-- alias (T5V.local) that sees past it. The common walk began 2 days ago, the alias's 5 days ago.
-- Each line makes one rule the only thing deciding it:
--
--   in window, seen 1 day ago                        stays (W1, W8-W10)
--   in window, seen 10 days ago                      marked by the venue's own walk (W2)
--   in window, seen 3 days ago by the alias only     marked: the venue's own walk vouches here (W3)
--   past the window, seen 3 days ago by the alias    STAYS: the capped walk could not see it (W4, W6)
--   past the window, seen 6 days ago                 marked, but only once the alias has FINISHED (W5)
--   in window, marked on 2026-01-01                  keeps its first mark (W7)
--   another venue, old, a FIGI inside the window     untouched: scopes do not leak (X1)
--   a REIT window where nothing was seen             REFUSED, nothing marked (R1-R3)
--   a depositary-receipt walk that has not finished  nothing marked (D1), though D2-D3 were
--                                                    seen, so the guard alone would not stop it

\set ON_ERROR_STOP on

begin;

insert into market.countries (iso2, name, flag, drillable) values ('ZU', 'Homeland', 'ZU', false)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix, preference, enabled) values
  ('T5V', 'ZU', '.ZV', 1, true), ('T5X', 'ZU', '.ZX', 2, true)
on conflict (exch_code) do update set enabled = true;
insert into market.directory_alias (query_key, exch_code_asked, files_under, security_type2, reason)
values ('T5V.local', 'T5L', 'T5V', 'Common Stock', 'fixture: sees past the capped walk')
on conflict (query_key) do nothing;

insert into market.venue_listing (figi, exch_code, ticker, security_type, last_seen_at, absent_since) values
  ('BBGT5V0100', 'T5V', 'W1', 'Common Stock', now() - interval '1 day',   null),
  ('BBGT5V0110', 'T5V', 'W8', 'Common Stock', now() - interval '1 day',   null),
  ('BBGT5V0120', 'T5V', 'W9', 'Common Stock', now() - interval '1 day',   null),
  ('BBGT5V0130', 'T5V', 'WA', 'Common Stock', now() - interval '1 day',   null),
  ('BBGT5V0200', 'T5V', 'W2', 'Common Stock', now() - interval '10 days', null),
  ('BBGT5V0300', 'T5V', 'W3', 'Common Stock', now() - interval '3 days',  null),
  ('BBGT5V0400', 'T5V', 'W7', 'Common Stock', now() - interval '90 days', '2026-01-01'),
  ('BBGT5V0700', 'T5V', 'W4', 'Common Stock', now() - interval '3 days',  null),
  ('BBGT5V0750', 'T5V', 'W6', 'Common Stock', now() - interval '3 days',  null),
  ('BBGT5V0800', 'T5V', 'W5', 'Common Stock', now() - interval '6 days',  null),
  ('BBGT5V0150', 'T5X', 'X1', 'Common Stock', now() - interval '30 days', null),
  ('BBGT5VR001', 'T5V', 'R1', 'REIT',         now() - interval '30 days', null),
  ('BBGT5VR002', 'T5V', 'R2', 'REIT',         now() - interval '30 days', null),
  ('BBGT5VR003', 'T5V', 'R3', 'REIT',         now() - interval '30 days', null),
  ('BBGT5VD001', 'T5V', 'D1', 'Depositary Receipt', now() - interval '30 days', null),
  -- Seen recently, so the guard would let an unfinished walk mark D1: only the unfinished rule stops it.
  ('BBGT5VD002', 'T5V', 'D2', 'Depositary Receipt', now() - interval '1 day',   null),
  ('BBGT5VD003', 'T5V', 'D3', 'Depositary Receipt', now() - interval '1 day',   null);

create temp table absent_after (step text, ticker text);
create temp table answer (step text, result jsonb);

-- 1. The alias has NOT finished: only the window is judged.
insert into answer
select 'alias unfinished', market.mark_venue_absence(jsonb_build_object(
  'T5V.common', jsonb_build_object('complete', true, 'started_at', now() - interval '2 days',
                                   'capped', true, 'window_end', 'BBGT5V0500'),
  'T5V.local',  jsonb_build_object('complete', false, 'started_at', now() - interval '5 days'),
  'T5V.reit',   jsonb_build_object('complete', true, 'started_at', now() - interval '2 days',
                                   'capped', false),
  'T5V.dr',     jsonb_build_object('complete', false, 'started_at', now() - interval '2 days')));
insert into absent_after select 'alias unfinished', ticker from market.venue_listing
 where figi like 'BBGT5V%' and absent_since is not null;

-- 2. The alias has finished: past the window is judged too.
insert into answer
select 'alias finished', market.mark_venue_absence(jsonb_build_object(
  'T5V.common', jsonb_build_object('complete', true, 'started_at', now() - interval '2 days',
                                   'capped', true, 'window_end', 'BBGT5V0500'),
  'T5V.local',  jsonb_build_object('complete', true, 'started_at', now() - interval '5 days'),
  'T5V.reit',   jsonb_build_object('complete', true, 'started_at', now() - interval '2 days',
                                   'capped', false),
  'T5V.dr',     jsonb_build_object('complete', false, 'started_at', now() - interval '2 days')));
insert into absent_after select 'alias finished', ticker from market.venue_listing
 where figi like 'BBGT5V%' and absent_since is not null;

do $$
declare
  first_step  text;
  second_step text;
begin
  select string_agg(ticker, ',' order by ticker) into first_step
    from absent_after where step = 'alias unfinished';
  select string_agg(ticker, ',' order by ticker) into second_step
    from absent_after where step = 'alias finished';
  if first_step is distinct from 'W2,W3,W7' then
    raise exception 'with the alias unfinished, absent lines are %, expected W2,W3,W7', first_step;
  end if;
  if second_step is distinct from 'W2,W3,W5,W7' then
    raise exception 'with the alias finished, absent lines are %, expected W2,W3,W5,W7', second_step;
  end if;
  if (select absent_since from market.venue_listing where figi = 'BBGT5V0400') <> '2026-01-01' then
    raise exception 'an earlier mark was overwritten';
  end if;
  if (select absent_since from market.venue_listing where figi = 'BBGT5V0150') is not null then
    raise exception 'a line of another venue was marked';
  end if;
  if not ((select result from answer where step = 'alias unfinished') -> 'refused') ? 'T5V.reit' then
    raise exception 'the REIT window where nothing was seen was not refused: %',
      (select result from answer where step = 'alias unfinished');
  end if;
  if not ((select result from answer where step = 'alias unfinished') -> 'unfinished') ? 'T5V.dr'
     or not ((select result from answer where step = 'alias unfinished') -> 'unfinished')
            ? 'T5V.common past BBGT5V0500' then
    raise exception 'an unfinished walk was not reported as unfinished: %',
      (select result from answer where step = 'alias unfinished');
  end if;
  if ((select result from answer where step = 'alias finished') ->> 'marked')::int <> 1 then
    raise exception 'the second call should mark exactly W5: %',
      (select result from answer where step = 'alias finished');
  end if;
end $$;

-- 3. The worker can call it; the public cannot.
do $$
begin
  if not has_function_privilege('ingest_rw', 'market.mark_venue_absence(jsonb)', 'EXECUTE') then
    raise exception 'ingest_rw cannot mark absence';
  end if;
  if has_function_privilege('anon', 'market.mark_venue_absence(jsonb)', 'EXECUTE') then
    raise exception 'anon can mark absence';
  end if;
end $$;

rollback;
