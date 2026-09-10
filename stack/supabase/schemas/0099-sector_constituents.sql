do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'sector_constituents';
  if k = 'm' then execute 'drop materialized view if exists market.sector_constituents cascade';
  elsif k = 'v' then execute 'drop view if exists market.sector_constituents cascade';
  end if;
end $$;
create view market.sector_constituents as
SELECT DISTINCT ON (tn.code, s.security_id) tn.code AS sector_id,
    s.security_id,
    s.name,
    sym.symbol,
    COALESCE(s.provider_country_iso2, s.country_iso2) AS country_iso2,
    ind.name AS industry,
    h.weight,
    h.fund_symbol,
    s.market_cap,
    s.currency_code,
    h.market_value,
    h.as_of
   FROM market.security_taxonomy st
     JOIN market.taxonomy_node tn ON tn.node_id = st.node_id AND tn.taxonomy_id = 'muffin'::text AND tn.level = 1
     JOIN market.data_source ds ON ds.code = st.source_code
     JOIN market.security s ON s.security_id = st.security_id
     LEFT JOIN market.security_symbol sym ON sym.security_id = s.security_id
     LEFT JOIN LATERAL ( SELECT n.name
           FROM market.security_taxonomy st2
             JOIN market.taxonomy_node n ON n.node_id = st2.node_id AND n.taxonomy_id = 'muffin'::text AND n.level = 2 AND n.parent_id = tn.node_id
          WHERE st2.security_id = s.security_id
         LIMIT 1) ind ON true
     LEFT JOIN LATERAL ( SELECT h_1.weight,
            h_1.market_value,
            h_1.as_of,
            fi.value AS fund_symbol
           FROM market.fund_holding_current h_1
             JOIN market.security_identifier fi ON fi.security_id = h_1.fund_id AND fi.kind_code = 'ticker'::text
             JOIN market.tracked_fund tf ON tf.symbol = fi.value AND tf.represents_code = tn.code
          WHERE h_1.security_id = s.security_id
         LIMIT 1) h ON true
  ORDER BY tn.code, s.security_id, ds.priority DESC, st.as_of DESC;
