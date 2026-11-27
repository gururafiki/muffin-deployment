CREATE OR REPLACE FUNCTION market.issuer_registry_filers()
 RETURNS TABLE(issuer_id uuid, security_id uuid, source_code text, filer_id text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'market', 'pg_catalog'
AS $function$
  -- The REGISTRY filers of equities that hold an annual accounts filing from that regulator. A
  -- sibling row is never one: once its history is copied it holds accounts itself, and counting it
  -- would make a company's own copy its source.
  select s.issuer_id, f.security_id, f.source_code, f.filer_id
    from market.security_filer f
    join market.disclosure_source d on d.code = f.source_code and d.enabled
    join market.security s on s.security_id = f.security_id
   where f.via = 'registry' and s.issuer_id is not null and s.security_type_code = 'equity'
     and exists (select 1
                   from market.security_filing sf
                   join market.filing_form ff
                     on ff.source_code = f.source_code and ff.form_code = sf.report_type
                  where sf.security_id = f.security_id and ff.is_annual and ff.carries_segments)
$function$;
