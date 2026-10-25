-- A LINE'S OWN VENUE VOUCHES FOR IT, AND AN ALIAS ONLY WHERE THE VENUE CANNOT SEE.
-- Decided by the user 2026-10-25 (umbrella docs/deferred/2026-10-04-a-stale-arca-line-keeps-a-us-
-- line-listed.md, option 1), due before the 1 November directory refresh.
--
-- WHY. The US directory reaches past OpenFIGI's 15,000-result cap through the alias `US.arca`, whose
-- NYSE Arca lines name their US line. D4 (20261004120000) let the venue's own walk judge inside its
-- window, but it read `last_seen_at`, which an alias sighting stamps too. Measured on the 2026-10-04
-- walks: Arca keeps 30 in-window lines for companies `US.common` no longer returns (Kirkland Lake,
-- Whiting, Tufin, …). They were marked only because `US.arca` walked first (12:15-12:19) and
-- `US.common` after (12:19-12:27). In the other order the Arca sighting is newer than the venue
-- walk's start, nothing is marked, and the trigger clears the marks already there. The order is a
-- property of partition keys, and the 1 November refresh re-walks every query.
--
-- THE FIX.
--   * `venue_listing.venue_seen_at`: the newest page of the line's OWN venue query that returned it.
--     Stage 2 stamps it only for a query that does not map to a composite (muffin-ingest).
--   * Inside a capped window, `mark_venue_absence` judges `venue_seen_at`. A line no venue page has
--     returned counts as unseen there, which is right: the venue's walk is the authority in-window.
--   * Past the window only the aliases see a line, so they keep judging `last_seen_at`, and a line
--     they return again is UN-marked there, at judgement, once every alias has finished.
--   * The trigger clears a mark only on a venue sighting NEWER THAN THE MARK. An alias sighting never
--     clears one, so filing Arca after the venue cannot undo the venue's verdict. Requiring the
--     sighting to post-date the mark also makes a stage-2 replay of an older page unable to clear it.
--
-- THE FILL. Which page returned a stored line is in raw, not here. The column is filled with
-- `last_seen_at` for every line except a MARKED one in a scope an alias also covers (US common
-- stock):
--   * outside an aliased scope the venue's walk is the only one, so the last sighting is its own;
--   * an unmarked in-window US line was returned by `US.common`, or the 10-04 judgement, which ran
--     after both walks with Arca first, would have marked it;
--   * an unmarked past-window US line gets Arca's time (12:18-12:19 on 10-04). That is not a venue
--     sighting, and no decision reads it: step 2 judges those lines by `last_seen_at`, and the value
--     is older than any mark, so it can never clear one. If the window grows to include the line,
--     the venue's next walk judges it as it should.
-- Measured before the fill (2026-10-25): US common stock 16,427 unmarked and 51 marked, with every
-- other US type and every other venue unaliased.
--
-- Guard: tests/an-alias-cannot-vouch-for-a-line-its-venue-can-see.sql.

alter table market.venue_listing add column if not exists venue_seen_at timestamptz;

comment on column market.venue_listing.venue_seen_at is
  'Fetch time of the newest page of this line''s own venue query that returned it. An alias page '
  '(a query mapping to a composite) stamps last_seen_at only. Inside a capped window the absence '
  'mark judges this, and only a venue sighting newer than a mark clears it. Lines stored before '
  '2026-10-25 were filled from last_seen_at (migration 20261025130000).';

-- BEFORE THE NEW TRIGGER EXISTS: the D4 trigger fires only on `update of last_seen_at`, which this
-- statement does not set, so the fill can neither move a sighting nor clear a mark.
update market.venue_listing v
   set venue_seen_at = v.last_seen_at
 where v.venue_seen_at is null
   and (v.absent_since is null
        or not exists (select 1 from market.directory_alias a
                        where a.files_under = v.exch_code and a.security_type2 = v.security_type));

create or replace function market.venue_listing_keeps_its_latest_sighting()
 returns trigger
 language plpgsql
 set search_path to 'market', 'pg_catalog', 'pg_temp'
as $function$
begin
  -- `greatest` ignores a null, so an alias page (no venue sighting) keeps the stored one.
  new.last_seen_at  := greatest(old.last_seen_at, new.last_seen_at);
  new.venue_seen_at := greatest(old.venue_seen_at, new.venue_seen_at);
  if old.absent_since is not null
     and new.venue_seen_at > coalesce(old.venue_seen_at, '-infinity'::timestamptz)
     and new.venue_seen_at > old.absent_since then
    new.absent_since := null;
  else
    new.absent_since := old.absent_since;
  end if;
  return new;
end;
$function$;

drop trigger if exists venue_listing_keeps_its_latest_sighting on market.venue_listing;
create trigger venue_listing_keeps_its_latest_sighting
  before update of last_seen_at, venue_seen_at on market.venue_listing
  for each row execute function market.venue_listing_keeps_its_latest_sighting();

create or replace function market.mark_venue_absence(p_walks jsonb)
 returns jsonb
 language plpgsql
 set search_path to 'market', 'pg_catalog', 'pg_temp'
as $function$
declare
  s            record;
  v_present    integer;
  v_seen       integer;
  v_n          integer;
  v_marked     integer := 0;
  v_cleared    integer := 0;
  v_judged     integer := 0;
  v_unfinished text[]  := '{}';
  v_refused    text[]  := '{}';
  v_by_scope   jsonb   := '{}';
begin
  if to_regclass('pg_temp.walk') is not null then drop table pg_temp.walk; end if;
  create temp table walk on commit drop as
  select q.query_key, q.files_under, q.security_type2, q.maps_to_composite,
         coalesce((w.value ->> 'complete')::boolean, false)  as complete,
         (w.value ->> 'started_at')::timestamptz              as started_at,
         coalesce((w.value ->> 'capped')::boolean, false)    as capped,
         nullif(w.value ->> 'window_end', '')                 as window_end
    from market.directory_query q
    left join jsonb_each(p_walks) w on w.key = q.query_key;

  for s in
    select d.query_key, d.files_under, d.security_type2, d.complete, d.started_at, d.capped,
           d.window_end,
           a.aliases, a.aliases_complete, a.aliases_started
      from walk d
      left join lateral (
        select count(*) as aliases,
               bool_and(x.complete and x.started_at is not null) as aliases_complete,
               min(x.started_at) as aliases_started
          from walk x
         where x.maps_to_composite
           and x.files_under = d.files_under and x.security_type2 = d.security_type2) a on true
     where not d.maps_to_composite
     order by d.query_key
  loop
    if not s.complete or s.started_at is null or (s.capped and s.window_end is null) then
      v_unfinished := v_unfinished || s.query_key;
      continue;
    end if;

    -- 1. The venue's own query: its whole scope, or its window when capped. Judged on the venue's
    --    OWN sighting, so an alias page filed after it cannot vouch for a line it no longer returns.
    select count(*) filter (where v.venue_seen_at >= s.started_at), count(*)
      into v_seen, v_present
      from market.venue_listing v
     where v.exch_code = s.files_under and v.security_type = s.security_type2
       and v.absent_since is null
       and (not s.capped or v.figi collate "C" <= s.window_end collate "C");
    if v_seen * 2 < v_present then
      v_refused := v_refused || s.query_key;
    else
      update market.venue_listing v
         set absent_since = now()
       where v.exch_code = s.files_under and v.security_type = s.security_type2
         and v.absent_since is null
         and coalesce(v.venue_seen_at, '-infinity'::timestamptz) < s.started_at
         and (not s.capped or v.figi collate "C" <= s.window_end collate "C");
      get diagnostics v_n = row_count;
      v_marked := v_marked + v_n;
      v_judged := v_judged + 1;
      if v_n > 0 then v_by_scope := v_by_scope || jsonb_build_object(s.query_key, v_n); end if;
    end if;

    -- 2. Past a capped window: the aliases, when every one has finished. They mark what they
    --    stopped returning, and un-mark what they return again, since the trigger never lets an
    --    alias sighting clear a mark.
    if s.capped and s.aliases > 0 then
      if not coalesce(s.aliases_complete, false) then
        v_unfinished := v_unfinished || (s.query_key || ' past ' || s.window_end);
        continue;
      end if;
      select count(*) filter (where v.last_seen_at >= s.aliases_started), count(*)
        into v_seen, v_present
        from market.venue_listing v
       where v.exch_code = s.files_under and v.security_type = s.security_type2
         and v.absent_since is null
         and v.figi collate "C" > s.window_end collate "C";
      if v_seen * 2 < v_present then
        v_refused := v_refused || (s.query_key || ' past ' || s.window_end);
      else
        update market.venue_listing v
           set absent_since = now()
         where v.exch_code = s.files_under and v.security_type = s.security_type2
           and v.absent_since is null
           and v.last_seen_at < s.aliases_started
           and v.figi collate "C" > s.window_end collate "C";
        get diagnostics v_n = row_count;
        v_marked := v_marked + v_n;
        v_judged := v_judged + 1;
        if v_n > 0 then
          v_by_scope := v_by_scope || jsonb_build_object(s.query_key || ' past ' || s.window_end, v_n);
        end if;
        update market.venue_listing v
           set absent_since = null
         where v.exch_code = s.files_under and v.security_type = s.security_type2
           and v.absent_since is not null
           and v.last_seen_at >= s.aliases_started
           and v.last_seen_at > v.absent_since
           and v.figi collate "C" > s.window_end collate "C";
        get diagnostics v_n = row_count;
        v_cleared := v_cleared + v_n;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'windows_judged', v_judged,
    'marked', v_marked,
    'cleared', v_cleared,
    'marked_by_window', v_by_scope,
    'unfinished', to_jsonb(v_unfinished),
    'refused', to_jsonb(v_refused),
    'absent', (select count(*) from market.venue_listing where absent_since is not null));
end;
$function$;
