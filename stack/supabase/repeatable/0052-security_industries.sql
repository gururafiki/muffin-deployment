do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_industries';
  if k = 'm' then execute 'drop materialized view if exists market.security_industries cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_industries cascade';
  end if;
end $$;
create view market.security_industries as
SELECT st.security_id,
    tn.taxonomy_id,
    tn.node_id,
    tn.code,
    tn.name,
    tn.level,
    parent.code AS parent_code,
    parent.name AS parent_name,
    st.source_code,
    ds.priority AS source_priority,
    st.weight,
    st.as_of
   FROM market.security_taxonomy st
     JOIN market.taxonomy_node tn ON tn.node_id = st.node_id
     LEFT JOIN market.taxonomy_node parent ON parent.node_id = tn.parent_id
     JOIN market.data_source ds ON ds.code = st.source_code;
