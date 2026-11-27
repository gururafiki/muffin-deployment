CREATE OR REPLACE FUNCTION market.extend_filers_to_issuer_siblings()
 RETURNS TABLE(inserted integer, retracted integer, refused integer)
 LANGUAGE plpgsql
 SET search_path TO 'market', 'pg_catalog'
AS $function$
declare
  v_inserted integer;
  v_retracted integer;
  v_refused integer;
begin
  -- A LINK THE RULE NO LONGER WANTS IS RETRACTED, and so is what it brought: the filings and
  -- segments of the accessions the filer's registry listings hold.
  with wanted as materialized (select * from market.issuer_sibling_links()),
  gone as (
    delete from market.security_filer f
     where f.via = 'issuer_sibling'
       and not exists (select 1 from wanted w
                        where w.security_id = f.security_id and w.source_code = f.source_code
                          and w.filer_id = f.filer_id)
    returning f.security_id, f.source_code, f.filer_id
  ), brought as materialized (
    select distinct g.security_id, sf.accession_number
      from gone g
      join market.security_filer r
        on r.source_code = g.source_code and r.filer_id = g.filer_id and r.via = 'registry'
      join market.security_filing sf on sf.security_id = r.security_id
  ), segments_gone as (
    delete from market.security_segment x
     using brought b
     where x.security_id = b.security_id and x.accession_number = b.accession_number
    returning 1
  ), filings_gone as (
    delete from market.security_filing x
     using brought b
     where x.security_id = b.security_id and x.accession_number = b.accession_number
    returning 1
  )
  select (select count(*) from gone) into v_retracted;

  insert into market.security_filer (security_id, source_code, filer_id, via)
  select w.security_id, w.source_code, w.filer_id, 'issuer_sibling'
    from market.issuer_sibling_links() w
  on conflict (security_id, source_code) do nothing;
  get diagnostics v_inserted = row_count;

  select count(*) into v_refused
    from (select h.issuer_id from market.issuer_registry_filers() h
           group by h.issuer_id
          having count(distinct (h.source_code, h.filer_id)) > 1) x;

  return query select v_inserted, v_retracted, v_refused;
end $function$;
