CREATE OR REPLACE FUNCTION market.copy_filer_history(p_security_id uuid, p_source text)
 RETURNS TABLE(filings integer, segments integer)
 LANGUAGE plpgsql
 SET search_path TO 'market', 'pg_catalog'
AS $function$
declare
  v_filer text;
  v_from uuid;
  v_version smallint;
  v_filings integer := 0;
  v_segments integer := 0;
  v_cols text;
  v_select text;
begin
  select f.filer_id into v_filer
    from market.security_filer f
   where f.security_id = p_security_id and f.source_code = p_source;
  select p.version into v_version from market.segment_parser p where p.regulator = p_source;
  if v_filer is null or v_version is null then
    return query select 0, 0;
    return;
  end if;

  -- THE SIBLING THAT HAS READ THE MOST, so a share class mapped yesterday is never the source.
  select r.security_id into v_from
    from market.security_filer r
   where r.source_code = p_source and r.filer_id = v_filer and r.security_id <> p_security_id
   order by (select count(*) from market.security_filing sf
              where sf.security_id = r.security_id
                and sf.segments_parser_version >= v_version) desc,
            r.security_id
   limit 1;
  if v_from is null then
    return query select 0, 0;
    return;
  end if;

  select string_agg(quote_ident(a.attname), ', ' order by a.attnum),
         string_agg(case when a.attname = 'security_id' then '$1' else 'x.' || quote_ident(a.attname) end,
                    ', ' order by a.attnum)
    into v_cols, v_select
    from pg_attribute a
   where a.attrelid = 'market.security_filing'::regclass and a.attnum > 0
     and not a.attisdropped and a.attgenerated = '';
  execute format('insert into market.security_filing (%s) select %s from market.security_filing x '
                 'where x.security_id = $2 on conflict (security_id, accession_number) do nothing',
                 v_cols, v_select)
    using p_security_id, v_from;
  get diagnostics v_filings = row_count;

  -- ONLY WHAT THE SOURCE READ AT THE CURRENT VERSION: a filing behind the parser is copied unread
  -- above (its own markers), and its segments arrive when the lane reads it for both listings.
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum),
         string_agg(case when a.attname = 'security_id' then '$1' else 'x.' || quote_ident(a.attname) end,
                    ', ' order by a.attnum)
    into v_cols, v_select
    from pg_attribute a
   where a.attrelid = 'market.security_segment'::regclass and a.attnum > 0
     and not a.attisdropped and a.attgenerated = '';
  execute format('insert into market.security_segment (%s) select %s from market.security_segment x '
                 'where x.security_id = $2 and exists (select 1 from market.security_filing f '
                 'where f.security_id = $2 and f.accession_number = x.accession_number '
                 'and f.segments_parser_version >= $3) on conflict do nothing',
                 v_cols, v_select)
    using p_security_id, v_from, v_version;
  get diagnostics v_segments = row_count;

  return query select v_filings, v_segments;
end $function$;
