CREATE OR REPLACE FUNCTION market.issuer_sibling_links()
 RETURNS TABLE(security_id uuid, source_code text, filer_id text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'market', 'pg_catalog'
AS $function$
  with held as materialized (select * from market.issuer_registry_filers()),
  by_issuer as materialized (
    select h.issuer_id, min(h.source_code) source_code, min(h.filer_id) filer_id
      from held h
     group by h.issuer_id
    -- ONE FILER PER ISSUER, or the issuer is refused: two filer ids is a question, not a choice.
    having count(distinct (h.source_code, h.filer_id)) = 1
  )
  select s.security_id, i.source_code, i.filer_id
    from by_issuer i
    join market.security s on s.issuer_id = i.issuer_id
   where s.security_type_code = 'equity'
     -- HOLES ONLY: a listing holding its own registry filer with accounts is served already.
     and not exists (select 1 from held h where h.security_id = s.security_id)
$function$;
