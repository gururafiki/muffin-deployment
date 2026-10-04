-- A line the venue directory stops returning is marked, and nothing offers or derives it.
-- Decision D4 of the umbrella's docs/specs/2026-10-04-the-venue-directory-asks-by-query.md.
--
-- WHY. `market.venue_listing` only ever grows: a line the provider stops returning keeps its row for
-- ever, looking current. The 2026-09-21 load found ~1,464 such lines the old table never retracted,
-- and three readers would act on them: the Markets search (`untracked_listing`) offers them as
-- "listed, not tracked", the Track button (`promote_listing`) mints a security for them, and
-- `derive_security_listing` keeps them as listings of tracked securities. Promotion waves (Stage 4)
-- would mint them by the thousand.
--
-- MARKED, NEVER DELETED: `security_listing` holds a foreign key to the line, and the history stays
-- readable. The muffin-ingest asset `venue_listing_absence` sets the mark through
-- `mark_venue_absence`; a NEWER sighting clears it, in the trigger below.
--
-- NAMED FOR WHAT IT MEASURES, `absent_since`, not `delisted_at`: the evidence is "the latest
-- complete walks able to see this line did not return it". For a US line past the 15,000-result
-- cap only the NYSE Arca walk can see it, so a stock moved from an exchange to OTC is absent too,
-- and still trades. A column claiming "delisted" would be wrong for exactly that case.

alter table market.venue_listing add column if not exists absent_since timestamptz;

comment on column market.venue_listing.absent_since is
  'When the latest complete walks able to see this line stopped returning it; null while returned. '
  'Set by market.mark_venue_absence (the Dagster asset venue_listing_absence), cleared by the next walk that returns it.';

-- LAST SEEN NEVER MOVES BACKWARDS, AND ONLY A NEWER SIGHTING CLEARS A MARK. Stage 2 stamps each
-- line with the fetch time of the page it came from. Re-filing an older raw file (a range re-run, a
-- fix to the parser, an alias walked before the venue's own) would otherwise move the sighting
-- back, letting the absence rule mark a line a newer walk returned — or clear a mark a newer walk
-- earned, so that the line is offered again until the next day's mark. A rule every writer must
-- remember is a trigger. The mark itself writes only `absent_since`, so it does not fire this.
create or replace function market.venue_listing_keeps_its_latest_sighting()
 returns trigger
 language plpgsql
 set search_path to 'market', 'pg_catalog', 'pg_temp'
as $function$
begin
  if new.last_seen_at > old.last_seen_at then
    new.absent_since := null;
  else
    new.last_seen_at := old.last_seen_at;
    new.absent_since := old.absent_since;
  end if;
  return new;
end;
$function$;

drop trigger if exists venue_listing_keeps_its_latest_sighting on market.venue_listing;
create trigger venue_listing_keeps_its_latest_sighting
  before update of last_seen_at on market.venue_listing
  for each row execute function market.venue_listing_keeps_its_latest_sighting();

-- THE MARK. The Dagster asset `venue_listing_absence` reads, from the raw files, each query's
-- current walk — complete or not, when it started, whether it hit OpenFIGI's 15,000-result cap,
-- and the last FIGI it holds — and passes them here. The rules live in the database, where CI tests
-- them against real Postgres; the facts live with the files they are read from.
--
-- A WALK VOUCHES ONLY FOR WHAT IT COULD SEE, and nothing is judged from an unfinished walk:
--   * the venue's own query (`US.common`) vouches for its scope's lines, or, when it is CAPPED,
--     only for lines up to the last FIGI it holds — walks are ordered by FIGI, so the window is
--     exactly the lines it could have returned;
--   * past that window only the aliases can see a line (`US.arca`), and they vouch for it only
--     when every alias of the scope has finished a walk.
-- A line is marked when it was last seen before the start of the latest complete walk able to see
-- it. Any walk that returns it stamps it, so a line `US.arca` returned stays unmarked even if
-- `US.common` did not.
--
-- A MASS MARK IS REFUSED, not applied. If fewer than half the unmarked lines of a window were seen
-- since its walk began, the likelier story is that stage 2 has not stamped the walk yet (or a
-- venue's code changed) than that most of a venue delisted in a month: the window is skipped and
-- named. This is the 1,369-security lesson: when nothing answers, blame the provider, not the
-- universe.
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

    -- 1. The venue's own query: its whole scope, or its window when capped.
    select count(*) filter (where v.last_seen_at >= s.started_at), count(*)
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
         and v.last_seen_at < s.started_at
         and (not s.capped or v.figi collate "C" <= s.window_end collate "C");
      get diagnostics v_n = row_count;
      v_marked := v_marked + v_n;
      v_judged := v_judged + 1;
      if v_n > 0 then v_by_scope := v_by_scope || jsonb_build_object(s.query_key, v_n); end if;
    end if;

    -- 2. Past a capped window: the aliases, when every one has finished.
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
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'windows_judged', v_judged,
    'marked', v_marked,
    'marked_by_window', v_by_scope,
    'unfinished', to_jsonb(v_unfinished),
    'refused', to_jsonb(v_refused),
    'absent', (select count(*) from market.venue_listing where absent_since is not null));
end;
$function$;

revoke all on function market.mark_venue_absence(jsonb) from public;
grant execute on function market.mark_venue_absence(jsonb) to ingest_rw;

-- THE THREE READERS. Their single definitions live in stack/supabase/schemas/ and are regenerated
-- from this migration; the view keeps its columns, so `create or replace` is enough.
create or replace view market.untracked_listing as
SELECT figi,
    composite_figi,
    exch_code,
    ticker,
    name,
    country_iso2,
    provider_symbol
   FROM market.venue_listing l
  WHERE name IS NOT NULL AND absent_since IS NULL AND NOT (EXISTS ( SELECT 1
           FROM market.security_identifier si
          WHERE si.kind_code = 'figi'::text AND si.value = l.composite_figi)) AND NOT (EXISTS ( SELECT 1
           FROM market.security_provider_symbol ps
          WHERE upper(ps.symbol) = upper(l.provider_symbol))) AND NOT (EXISTS ( SELECT 1
           FROM market.security_identifier ti
          WHERE ti.kind_code = 'ticker'::text AND upper(ti.value) = upper(l.provider_symbol)));

CREATE OR REPLACE FUNCTION market.derive_security_listing()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  v_lines      integer;
  v_securities integer;
  v_inserted   integer;
  v_changed    integer;
  v_retracted  integer;
  v_demoted    integer;
  v_promoted   integer;
  v_by_symbol  integer;
  v_by_legacy  integer;
  v_by_home    integer;
  v_currency   integer;
begin
  -- 1. Every line of every tracked share class.
  -- A second call in one transaction finds the first call's tables; `drop ... if exists` would
  -- say so as a NOTICE on every ordinary call.
  if to_regclass('pg_temp.derived_line') is not null then drop table pg_temp.derived_line; end if;
  create temp table derived_line on commit drop as
  select v.figi, i.security_id, v.exch_code, v.ticker, v.provider_symbol, v.last_seen_at,
         count(*) over (partition by i.security_id, v.exch_code) as lines_on_venue
    from market.venue_listing v
    join market.security_identifier i
      on i.kind_code = 'share_class_figi' and i.value = v.share_class_figi
   -- A LINE THE DIRECTORY NO LONGER RETURNS IS NOT A LISTING. Step 3 then retracts it.
   where v.absent_since is null;
  get diagnostics v_lines = row_count;
  select count(distinct security_id) into v_securities from derived_line;

  -- 2. Store them. A line whose class moved to another security arrives there NOT primary: that
  --    security may already have one, and the partial unique index would refuse the move.
  with written as (
    insert into market.security_listing as sl
           (figi, security_id, currency_code, first_seen_at, last_seen_at)
    select l.figi, l.security_id,
           (select lg.currency_code
              from market.listing lg
             where lg.security_id = l.security_id
               and lg.exch_code   = l.exch_code
               and lg.currency_code is not null
               and (lg.provider_symbol = l.provider_symbol
                    or lg.symbol = l.ticker
                    or l.lines_on_venue = 1)
             order by (lg.provider_symbol = l.provider_symbol) desc nulls last, lg.is_primary desc
             limit 1),
           now(), coalesce(l.last_seen_at, now())
      from derived_line l
    on conflict (figi) do update
       set security_id   = excluded.security_id,
           is_primary    = sl.is_primary and sl.security_id = excluded.security_id,
           currency_code = coalesce(sl.currency_code, excluded.currency_code),
           last_seen_at  = excluded.last_seen_at
     where sl.security_id is distinct from excluded.security_id
        or (sl.currency_code is null and excluded.currency_code is not null)
        or sl.last_seen_at is distinct from excluded.last_seen_at
    returning (xmax = 0) as inserted
  )
  select count(*) filter (where inserted), count(*) filter (where not inserted)
    into v_inserted, v_changed
    from written;

  -- 3. Retract what the directory no longer says: a line gone from the sweep, or a class no
  --    longer tracked.
  delete from market.security_listing sl
   where not exists (select 1 from derived_line l
                      where l.figi = sl.figi and l.security_id = sl.security_id);
  get diagnostics v_retracted = row_count;

  -- 4. Choose one primary per security, by the rules in the header.
  if to_regclass('pg_temp.derived_primary') is not null then drop table pg_temp.derived_primary; end if;
  create temp table derived_primary on commit drop as
  select distinct on (l.security_id) l.security_id, l.figi,
         case when m.held > 0 then 'held symbol'
              when lp.exch_code is not null then 'legacy primary venue'
              else 'home venue' end as reason
    from derived_line l
    join market.security s on s.security_id = l.security_id
    left join market.security_provider_symbol p
           on p.security_id = l.security_id and p.provider_code = 'yfinance'
    cross join lateral (
      select case when p.symbol = l.provider_symbol then 2
                  when market.symbol_match_key(p.symbol)
                       = market.symbol_match_key(l.provider_symbol) then 1
                  else 0 end as held) m
    left join market.listing lp
           on lp.security_id = l.security_id and lp.is_primary and lp.exch_code = l.exch_code
    left join market.exchange e
           on e.exch_code = l.exch_code
          and e.country_iso2 = coalesce(s.provider_country_iso2, s.country_iso2)
   where m.held > 0 or lp.exch_code is not null or e.exch_code is not null
   order by l.security_id, m.held desc, (lp.exch_code is not null) desc,
            e.preference nulls last, length(l.ticker), l.figi;

  select count(*) filter (where reason = 'held symbol'),
         count(*) filter (where reason = 'legacy primary venue'),
         count(*) filter (where reason = 'home venue')
    into v_by_symbol, v_by_legacy, v_by_home
    from derived_primary;

  -- 5. Move the flag in TWO statements, demote first. The unique index on (security_id) where
  --    is_primary is checked row by row, so one statement flipping two rows can fail on whichever
  --    it visits first.
  update market.security_listing sl
     set is_primary = false
   where sl.is_primary
     and not exists (select 1 from derived_primary c where c.figi = sl.figi);
  get diagnostics v_demoted = row_count;

  update market.security_listing sl
     set is_primary = true
    from derived_primary c
   where c.figi = sl.figi
     and not sl.is_primary;
  get diagnostics v_promoted = row_count;

  select count(*) into v_currency from market.security_listing where currency_code is not null;

  return jsonb_build_object(
    'lines', v_lines,
    'securities', v_securities,
    'inserted', v_inserted,
    'changed', v_changed,
    'retracted', v_retracted,
    'primary_by_symbol', v_by_symbol,
    'primary_by_legacy_venue', v_by_legacy,
    'primary_by_home_venue', v_by_home,
    'without_primary', v_securities - v_by_symbol - v_by_legacy - v_by_home,
    'primaries_demoted', v_demoted,
    'primaries_promoted', v_promoted,
    'with_currency', v_currency);
end;
$function$;

CREATE OR REPLACE FUNCTION market.promote_listing(p_figi text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'public'
AS $function$
declare
  v_claims jsonb;
  v_role text;
  v_listing record;
  v_security_id uuid;
  v_symbol text := null;
begin
  -- THE JWT CLAIMS COME FROM PostgREST's GUC, read directly rather than through auth.jwt() so the
  -- function does not depend on the Supabase auth schema (which a migration harness may lack).
  -- `app_metadata.role` is the ONE place a role cannot be self-assigned (user_metadata is writable
  -- through the ordinary auth API); the edge function enforces the same check on the same field.
  v_claims := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
  v_role := v_claims #>> '{app_metadata,role}';
  -- WRITTEN POSITIVELY AND COALESCED, the falsy-NULL gate this schema has paid for once: with no
  -- JWT at all, `v_role` is NULL and `NULL <> 'admin'` is NULL, so the obvious negation lets the
  -- gate FAIL OPEN — an unauthenticated caller would promote anything.
  if not coalesce(v_role = 'admin' or (v_claims #> '{app_metadata,roles}' ? 'admin'), false) then
    return jsonb_build_object('promoted', false, 'reason', 'admins only');
  end if;

  if p_figi is null or length(trim(p_figi)) = 0 then
    return jsonb_build_object('promoted', false, 'reason', 'a figi is required');
  end if;

  -- Already ours is a SUCCESS (a no-op), not an error — two people tapping the same row must not
  -- fail for the second one.
  if exists (select 1 from market.security_identifier
              where kind_code = 'figi' and value = p_figi) then
    return jsonb_build_object('figi', p_figi, 'promoted', false, 'reason', 'already tracked');
  end if;

  select * into v_listing from market.venue_listing where figi = p_figi;
  if v_listing.figi is null then
    -- NOT IN THE DIRECTORY, AND THERE IS NO FALLBACK ANY MORE. The discovery sweep must have
    -- reached the listing first; telling the caller honestly beats inventing a security from a
    -- ticker that might mean a different company in a different venue.
    return jsonb_build_object('figi', p_figi, 'promoted', false,
                              'reason', 'unknown figi — the venue sweep has not catalogued it');
  end if;

  -- A LINE THE DIRECTORY STOPPED RETURNING IS NOT OFFERED, so it cannot be tracked by hand either:
  -- minting a security for a delisted company spends a month of provider calls on nothing.
  if v_listing.absent_since is not null then
    return jsonb_build_object('figi', p_figi, 'promoted', false,
                              'reason', 'the venue directory has not returned this listing since '
                                        || to_char(v_listing.absent_since, 'YYYY-MM-DD'));
  end if;

  v_security_id := gen_random_uuid();

  insert into market.security (security_id, name, security_type_code, country_iso2, is_tradeable)
  values (v_security_id, v_listing.name, 'equity', v_listing.country_iso2, true);

  -- FIGI first, because it is what stops this listing being offered as untracked again. A row's
  -- `composite_figi` can be NULL (a listing with no composite), in which case its own FIGI holds —
  -- the edge handler coalesced the same way.
  insert into market.security_identifier (kind_code, value, security_id, source_code)
  values ('figi', coalesce(v_listing.composite_figi, p_figi), v_security_id, 'openfigi'),
         ('ticker', upper(v_listing.ticker), v_security_id, 'openfigi')
  on conflict (kind_code, value) do nothing;

  if v_listing.provider_symbol is not null then
    insert into market.security_provider_symbol (security_id, provider_code, symbol)
    values (v_security_id, 'yfinance', v_listing.provider_symbol)
    on conflict (security_id, provider_code) do nothing;
    v_symbol := v_listing.provider_symbol;
  else
    v_symbol := v_listing.ticker;
  end if;

  return jsonb_build_object(
    'figi', p_figi,
    'promoted', true,
    'securityId', v_security_id,
    'symbol', v_symbol,
    'note', 'sector and returns arrive on the next security-profiles / security-performance run'
  );
end;
$function$;
