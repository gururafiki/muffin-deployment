-- A tracked security's listings are DERIVED from the directory. Stage 2b of the umbrella's
-- docs/specs/2026-09-26-finishing-the-universe-family.md.
--
-- A security is one OpenFIGI share class (`security_identifier` kind `share_class_figi`), and a
-- listing is one line of that class on one venue: a row of `venue_listing`, which the Dagster
-- sweep writes. So a security's listings are a JOIN the database can already answer. This
-- function answers it and stores the result in `security_listing`, choosing one line per security
-- as primary. The Dagster asset `security_listing` is a thin caller that records the counts.
--
-- WHY SQL AND NOT PYTHON. No provider is asked; the inputs are three tables this database holds.
-- In SQL the rules are tested against real Postgres in CI, with fixtures that make them disagree.
--
-- MEASURED 2026-09-27 by running this function on production in a rolled-back transaction:
--
--   lines of tracked share classes              33,859, for 11,476 securities, in 2.7 s
--   securities holding a yfinance symbol        11,033
--     the symbol names one of its lines         9,837 exactly
--                                               390 only through `symbol_match_key`: separators
--                                                   (GETI-B.ST is GETIB.ST in the directory,
--                                                   BBL-F.BK is BBL/F.BK, VESTA.MX is VESTA*.MX)
--                                                   and, for 152 of them, Hong Kong's zero padding
--                                                   (0586.HK is 586.HK)
--                                               806 not at all: India spells differently
--                                                   (CONCORDBIO.NS against CONCORDB.NS), and US
--                                                   lines past OpenFIGI's 15,000-result cap are
--                                                   missing (docs/deferred/2026-09-27-the-us-
--                                                   directory-stops-at-15000.md, umbrella)
--   primary by the held symbol                  10,227
--           by the legacy primary venue         972
--           by the home venue                   16
--   no primary                                  261
--   primary on the legacy primary's venue       10,983; on another venue 54; no legacy primary 178
--   a second run                                inserted 0, changed 0, retracted 0, promoted 0
--
-- THE PRIMARY LINE, in order:
--   1. the line we PRICE: its market spelling matches the held yfinance symbol, exactly first;
--   2. the venue the legacy `market.listing` marked primary. The edge functions decided it and no
--      longer run; it stays as the tie-break for the securities the first rule cannot place;
--   3. the security's home venue, by `market.exchange.preference`. "Home" is the EFFECTIVE country,
--      operating before filed, the value `security_current` answers with;
--   4. then the shortest ticker (BMA before BMAD and BMA/C, three lines of one class in Buenos
--      Aires), then the FIGI.
-- A security none of the first three rules can place gets NO primary rather than an arbitrary
-- foreign line. `security_symbol` and `security_currency` then fall back as they do today.
--
-- THE CURRENCY. The directory carries none. It is carried from the legacy row for the same
-- security and venue, and only to the line that row names: by symbol, or because it is the
-- security's only line on that venue. Once set it is never overwritten, because a legacy row is a
-- record of a past fetch and the derived row may since have been corrected.
--
-- CHEAP TO RE-RUN. The asset fires whenever the directory or the symbology lane changes, so an
-- unchanged row is not rewritten. `last_seen_at` is the directory's own `last_seen_at` for the
-- line, which moves only when a sweep re-reads the venue.
--
-- NOT SECURITY DEFINER, like `apply_cik_map`. The worker gains exactly what it could already do as
-- `ingest_rw`, and the one-primary rule it must not skip.
--
-- AFTER STAGE 2C, `market.listing` becomes a view over this table and the legacy rows are renamed
-- `listing_legacy`. Then the two legacy reads below must read `listing_legacy`.

create or replace function market.symbol_match_key(p_symbol text)
returns text
language sql
immutable strict parallel safe
set search_path to 'pg_catalog'
as $function$
  -- The key two spellings of ONE line share. Bloomberg and Yahoo disagree on class separators
  -- (`BRK/B` and `BRK-B`, `VESTA*` and `VESTA`), and Yahoo pads a Hong Kong code to four digits.
  -- The venue suffix after the last dot is compared as it is. Compare only within one security's
  -- own lines: this is a matching key, never a spelling to adopt.
  select upper(case when b ~ '^[0-9]+$' then coalesce(nullif(ltrim(b, '0'), ''), '0') else b end)
         || upper(s)
    from (select regexp_replace(coalesce(substring(p_symbol from '^(.*)\.[^.]*$'), p_symbol),
                                '[-/*. ]', '', 'g') as b,
                 coalesce(substring(p_symbol from '(\.[^.]*)$'), '') as s) parts
$function$;

create or replace function market.derive_security_listing()
returns jsonb
language plpgsql
set search_path to 'market', 'pg_catalog', 'pg_temp'
as $function$
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
      on i.kind_code = 'share_class_figi' and i.value = v.share_class_figi;
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

comment on function market.derive_security_listing() is
  'Derives market.security_listing from the directory (venue_listing joined to the tracked share '
  'classes), retracts what the directory no longer says, and chooses one primary line per '
  'security. Called by the Dagster asset security_listing; returns counts.';

-- The worker calls it; nothing else should. Functions are executable by PUBLIC by default, and
-- `market` is exposed through PostgREST.
revoke execute on function market.derive_security_listing() from public;
grant execute on function market.derive_security_listing() to ingest_rw, service_role;
