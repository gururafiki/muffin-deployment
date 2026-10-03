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
