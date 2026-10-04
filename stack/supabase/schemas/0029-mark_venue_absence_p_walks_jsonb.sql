CREATE OR REPLACE FUNCTION market.mark_venue_absence(p_walks jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
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
