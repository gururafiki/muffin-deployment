CREATE OR REPLACE FUNCTION market.derive_sic_classification()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare written integer := 0;
begin
  with emitted as (
    insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
    select s.security_id, tn.node_id, 'sic', now()
    from market.security s
    join market.taxonomy_node tn
      on tn.taxonomy_id = 'sic' and tn.code = lpad(s.sic, 4, '0')
    where s.sic is not null
    -- `do nothing`: the row carries no derived value to refresh, so re-writing it every day would
    -- churn `as_of` and the WAL for nothing.
    on conflict (security_id, node_id, source_code) do nothing
    returning 1
  )
  select count(*) into written from emitted;

  -- A registrant whose SIC changed keeps the old node otherwise — an upsert cannot retract.
  delete from market.security_taxonomy st
   using market.taxonomy_node tn, market.security s
   where st.source_code = 'sic'
     and tn.node_id = st.node_id
     and s.security_id = st.security_id
     and (s.sic is null or tn.code <> lpad(s.sic, 4, '0'));

  return written;
end $function$;
