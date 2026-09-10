do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'fund_sector_weight';
  if k = 'm' then execute 'drop materialized view if exists market.fund_sector_weight cascade';
  elsif k = 'v' then execute 'drop view if exists market.fund_sector_weight cascade';
  end if;
end $$;
create view market.fund_sector_weight as
WITH classified AS (
         SELECT DISTINCT ON (st.security_id) st.security_id,
            tn.code
           FROM market.security_taxonomy st
             JOIN market.taxonomy_node tn ON tn.node_id = st.node_id AND tn.taxonomy_id = 'muffin'::text AND tn.level = 1
             JOIN market.data_source ds ON ds.code = st.source_code
          ORDER BY st.security_id, ds.priority DESC, st.as_of DESC
        )
 SELECT fi.value AS fund_symbol,
    COALESCE(c.code, 'unclassified'::text) AS sector_id,
    sum(h.weight) AS weight,
    round(100::numeric * sum(h.weight) / NULLIF(sum(sum(h.weight)) OVER (PARTITION BY fi.value), 0::numeric), 4) AS weight_pct,
    max(h.as_of) AS as_of
   FROM market.fund_holding_current h
     JOIN market.security_identifier fi ON fi.security_id = h.fund_id AND fi.kind_code = 'ticker'::text
     JOIN market.security s ON s.security_id = h.security_id AND s.security_type_code = 'equity'::text
     LEFT JOIN classified c ON c.security_id = h.security_id
  WHERE h.security_id <> h.fund_id
  GROUP BY fi.value, (COALESCE(c.code, 'unclassified'::text));
