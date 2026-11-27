CREATE OR REPLACE FUNCTION market.filer_holders_to_copy()
 RETURNS TABLE(security_id uuid, source_code text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'market', 'pg_catalog'
AS $function$
  -- A HOLDER WITH NONE OF ITS FILER'S HISTORY, beside another holder that has some: a sibling just
  -- linked, an H-share line CNINFO's HK list just mapped, a share class a registry just mapped. Once
  -- copied it holds the history and drops out, so the copy runs once per holder.
  select f.security_id, f.source_code
    from market.security_filer f
    join market.disclosure_source d on d.code = f.source_code and d.enabled
   where exists (select 1
                   from market.security_filer o
                   join market.security_filing osf on osf.security_id = o.security_id
                  where o.source_code = f.source_code and o.filer_id = f.filer_id
                    and o.security_id <> f.security_id)
     and not exists (select 1
                       from market.security_filing sf
                       join market.security_filer o
                         on o.source_code = f.source_code and o.filer_id = f.filer_id
                        and o.security_id <> f.security_id
                       join market.security_filing osf
                         on osf.security_id = o.security_id
                        and osf.accession_number = sf.accession_number
                      where sf.security_id = f.security_id)
$function$;
