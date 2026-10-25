-- Inside a capped venue's window only the venue's own page vouches for a line, whichever query was
-- walked last; past the window the aliases do, and they can un-mark what they see again.
-- Migration 20261025130000.
--
-- WHY. NYSE Arca keeps lines for US companies that are gone (30 inside `US.common`'s window on
-- 2026-10-04). When `US.arca` was filed AFTER `US.common`, its sighting was newer than the venue
-- walk's start, so the D4 rule (which read `last_seen_at`) marked none of them, and the D4 trigger
-- cleared the marks already there. The order is an accident of partition keys.
--
-- The fixture is venue T6V, capped at BBGT6V0500, with alias T6V.arca. The venue walk began 2 days
-- ago and the alias's 1.5 days ago, so every alias sighting below is NEWER than the venue's start,
-- which is exactly the order D4 got wrong. Each line makes one rule the only thing deciding it:
--
--   A1  in window, the venue saw it 1 day ago                       stays
--   A2  in window, the venue 10 days ago, the alias 1 day ago       MARKED (the walk-order case)
--   A3  in window, never returned by the venue, the alias 1 day ago MARKED (an unseen line is unseen)
--   P1  past the window, marked 3 days ago, the alias 1 day ago     UN-MARKED at judgement
--   P2  past the window, marked 3 days ago, the alias 5 days ago    stays marked
--   P3  past the window, the alias 1 day ago                        stays
--
-- Then the trigger, on M1, an in-window line marked 2 days ago:
--   an alias page (newer `last_seen_at`, no venue sighting)          keeps the mark
--   the same alias page through the stage-2 upsert                   keeps the mark AND the stored
--                                                                    `venue_seen_at` (a null must
--                                                                    not overwrite it)
--   a replayed venue page OLDER than the mark                        keeps the mark
--   a venue page newer than the mark                                 clears it
--
-- Last, the one-time fill, run from the migration file itself.

\set ON_ERROR_STOP on

begin;

insert into market.countries (iso2, name, flag, drillable) values ('ZU', 'Homeland', 'ZU', false)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix, preference, enabled) values
  ('T6V', 'ZU', '.ZV', 1, true)
on conflict (exch_code) do update set enabled = true;
insert into market.directory_alias (query_key, exch_code_asked, files_under, security_type2, reason)
values ('T6V.arca', 'T6A', 'T6V', 'Common Stock', 'fixture: sees past the capped walk, and keeps the dead')
on conflict (query_key) do nothing;

insert into market.venue_listing (figi, exch_code, ticker, security_type, last_seen_at, venue_seen_at,
                                  absent_since) values
  ('BBGT6V0100', 'T6V', 'A1', 'Common Stock', now() - interval '1 day',   now() - interval '1 day',   null),
  ('BBGT6V0110', 'T6V', 'B1', 'Common Stock', now() - interval '1 day',   now() - interval '1 day',   null),
  ('BBGT6V0120', 'T6V', 'B2', 'Common Stock', now() - interval '1 day',   now() - interval '1 day',   null),
  ('BBGT6V0130', 'T6V', 'B3', 'Common Stock', now() - interval '1 day',   now() - interval '1 day',   null),
  ('BBGT6V0200', 'T6V', 'A2', 'Common Stock', now() - interval '1 day',   now() - interval '10 days', null),
  ('BBGT6V0300', 'T6V', 'A3', 'Common Stock', now() - interval '1 day',   null,                       null),
  ('BBGT6V0700', 'T6V', 'P1', 'Common Stock', now() - interval '1 day',   null, now() - interval '3 days'),
  ('BBGT6V0750', 'T6V', 'P2', 'Common Stock', now() - interval '5 days',  null, now() - interval '3 days'),
  ('BBGT6V0800', 'T6V', 'P3', 'Common Stock', now() - interval '1 day',   null,                       null),
  ('BBGT6V0810', 'T6V', 'P4', 'Common Stock', now() - interval '1 day',   null,                       null);

create temp table answer as
select market.mark_venue_absence(jsonb_build_object(
  'T6V.common', jsonb_build_object('complete', true, 'started_at', now() - interval '2 days',
                                   'capped', true, 'window_end', 'BBGT6V0500'),
  'T6V.arca',   jsonb_build_object('complete', true, 'started_at', now() - interval '36 hours')))
  as result;

do $$
declare
  absent text;
  r      jsonb := (select result from answer);
begin
  select string_agg(ticker, ',' order by ticker) into absent
    from market.venue_listing where figi like 'BBGT6V%' and absent_since is not null;
  if absent is distinct from 'A2,A3,P2' then
    raise exception 'absent lines are %, expected A2,A3,P2 (A2: an alias page filed after the venue '
                    'must not vouch in-window; A3: a line the venue never returned is unseen; '
                    'P1: an alias that sees a past-window line again must un-mark it): %', absent, r;
  end if;
  if (r ->> 'marked')::int <> 2 or (r ->> 'cleared')::int <> 1 then
    raise exception 'expected 2 marked and 1 cleared, got %', r;
  end if;
  raise notice 'ok  in-window lines are judged by the venue''s page, past the window by the alias''s';
end $$;

-- The trigger.
insert into market.venue_listing (figi, exch_code, ticker, security_type, last_seen_at, venue_seen_at,
                                  absent_since)
values ('BBGT6V0400', 'T6V', 'M1', 'Common Stock', now() - interval '10 days', now() - interval '10 days',
        now() - interval '2 days');

do $$
declare
  marked timestamptz := now() - interval '2 days';
begin
  -- An alias page: a newer `last_seen_at`, no venue sighting.
  update market.venue_listing set last_seen_at = now() where figi = 'BBGT6V0400';
  if (select absent_since from market.venue_listing where figi = 'BBGT6V0400') is distinct from marked then
    raise exception 'an alias sighting cleared an in-window mark: walk order decides the answer again';
  end if;
  if (select last_seen_at from market.venue_listing where figi = 'BBGT6V0400') <> now() then
    raise exception 'an alias sighting did not move last_seen_at forward';
  end if;
end $$;

-- The same alias page as stage 2 sends it: every column the row carries, `venue_seen_at` null.
insert into market.venue_listing (figi, exch_code, ticker, security_type, last_seen_at, venue_seen_at)
values ('BBGT6V0400', 'T6V', 'M1', 'Common Stock', now() + interval '1 hour', null)
on conflict (figi) do update
   set exch_code = excluded.exch_code, ticker = excluded.ticker,
       last_seen_at = excluded.last_seen_at, venue_seen_at = excluded.venue_seen_at;

do $$
declare
  marked timestamptz := now() - interval '2 days';
begin
  if (select absent_since from market.venue_listing where figi = 'BBGT6V0400') is distinct from marked then
    raise exception 'an alias page through the stage-2 upsert cleared an in-window mark';
  end if;
  if (select venue_seen_at from market.venue_listing where figi = 'BBGT6V0400')
     is distinct from now() - interval '10 days' then
    raise exception 'an alias page through the upsert overwrote the stored venue sighting with %',
      (select venue_seen_at from market.venue_listing where figi = 'BBGT6V0400');
  end if;

  -- A replayed venue page: newer than the stored sighting, OLDER than the mark.
  update market.venue_listing set venue_seen_at = now() - interval '5 days' where figi = 'BBGT6V0400';
  if (select absent_since from market.venue_listing where figi = 'BBGT6V0400') is distinct from marked then
    raise exception 'a venue page fetched before the mark cleared it (a stage-2 replay would un-mark)';
  end if;
  if (select venue_seen_at from market.venue_listing where figi = 'BBGT6V0400')
     is distinct from now() - interval '5 days' then
    raise exception 'a newer venue sighting did not move venue_seen_at forward';
  end if;

  -- A venue page fetched after the mark.
  update market.venue_listing set venue_seen_at = now() where figi = 'BBGT6V0400';
  if (select absent_since from market.venue_listing where figi = 'BBGT6V0400') is not null then
    raise exception 'a venue page newer than the mark did not clear it';
  end if;
  raise notice 'ok  only the venue''s own page, fetched after the mark, clears it';
end $$;

-- The one-time fill, from the migration file itself: a venue's only sighting is its own, an
-- unmarked line keeps its last sighting, and a MARKED line in an aliased scope gets none.
insert into market.exchange (exch_code, country_iso2, suffix, preference, enabled) values
  ('T6W', 'ZU', '.ZW', 2, true)
on conflict (exch_code) do update set enabled = true;
insert into market.venue_listing (figi, exch_code, ticker, security_type, last_seen_at, absent_since) values
  ('BBGT6W0100', 'T6W', 'F1', 'Common Stock', now() - interval '20 days', now() - interval '3 days'),
  ('BBGT6V0900', 'T6V', 'F2', 'Common Stock', now() - interval '20 days', null),
  ('BBGT6V0910', 'T6V', 'F3', 'Common Stock', now() - interval '20 days', now() - interval '3 days');

\i stack/supabase/migrations/20261025130000_a_line_s_own_venue_vouches_for_it.sql

do $$
begin
  if (select venue_seen_at from market.venue_listing where figi = 'BBGT6W0100')
     is distinct from now() - interval '20 days' then
    raise exception 'a marked line of an unaliased venue was not filled from its own sighting';
  end if;
  if (select absent_since from market.venue_listing where figi = 'BBGT6W0100') is null then
    raise exception 'the fill cleared a mark';
  end if;
  if (select venue_seen_at from market.venue_listing where figi = 'BBGT6V0900')
     is distinct from now() - interval '20 days' then
    raise exception 'an unmarked line in an aliased scope was not filled';
  end if;
  if (select venue_seen_at from market.venue_listing where figi = 'BBGT6V0910') is not null then
    raise exception 'a marked line in an aliased scope was given a venue sighting it may not have had';
  end if;
  raise notice 'ok  the fill gives a venue sighting only where the venue was the only one looking';
end $$;

rollback;
