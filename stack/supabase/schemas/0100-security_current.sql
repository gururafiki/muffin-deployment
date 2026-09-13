do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_current';
  if k = 'm' then execute 'drop materialized view if exists market.security_current cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_current cascade';
  end if;
end $$;
create view market.security_current as
SELECT s.security_id,
    s.name,
    s.security_type_code,
    COALESCE(s.provider_country_iso2, s.country_iso2) AS country_iso2,
    s.currency_code,
    s.is_tradeable,
    s.market_cap,
    sym.symbol,
    isin.value AS isin,
    i.name AS issuer_name,
    c.name AS country_name,
    ( SELECT tn.code
           FROM market.security_taxonomy st
             JOIN market.taxonomy_node tn ON tn.node_id = st.node_id AND tn.taxonomy_id = 'muffin'::text AND tn.level = 1
             JOIN market.data_source ds ON ds.code = st.source_code
          WHERE st.security_id = s.security_id
          ORDER BY ds.priority DESC, st.as_of DESC
         LIMIT 1) AS sector_id,
    ( SELECT n.name
           FROM market.security_taxonomy st2
             JOIN market.taxonomy_node n ON n.node_id = st2.node_id AND n.taxonomy_id = 'muffin'::text AND n.level = 2 AND n.parent_id = (( SELECT tn.node_id
                   FROM market.security_taxonomy st_sec
                     JOIN market.taxonomy_node tn ON tn.node_id = st_sec.node_id AND tn.taxonomy_id = 'muffin'::text AND tn.level = 1
                     JOIN market.data_source ds_sec ON ds_sec.code = st_sec.source_code
                  WHERE st_sec.security_id = s.security_id
                  ORDER BY ds_sec.priority DESC, st_sec.as_of DESC
                 LIMIT 1))
             JOIN market.data_source ds2 ON ds2.code = st2.source_code
          WHERE st2.security_id = s.security_id
          ORDER BY ds2.priority DESC, st2.as_of DESC
         LIMIT 1) AS industry,
    ( SELECT n.code
           FROM market.security_taxonomy st2
             JOIN market.taxonomy_node n ON n.node_id = st2.node_id AND n.taxonomy_id = 'muffin'::text AND n.level = 2 AND n.parent_id = (( SELECT tn.node_id
                   FROM market.security_taxonomy st_sec
                     JOIN market.taxonomy_node tn ON tn.node_id = st_sec.node_id AND tn.taxonomy_id = 'muffin'::text AND tn.level = 1
                     JOIN market.data_source ds_sec ON ds_sec.code = st_sec.source_code
                  WHERE st_sec.security_id = s.security_id
                  ORDER BY ds_sec.priority DESC, st_sec.as_of DESC
                 LIMIT 1))
             JOIN market.data_source ds2 ON ds2.code = st2.source_code
          WHERE st2.security_id = s.security_id
          ORDER BY ds2.priority DESC, st2.as_of DESC
         LIMIT 1) AS industry_code,
    s.country_iso2 AS filed_country_iso2,
    s.provider_country_iso2
   FROM market.security s
     LEFT JOIN market.security_symbol sym ON sym.security_id = s.security_id
     LEFT JOIN market.security_identifier isin ON isin.security_id = s.security_id AND isin.kind_code = 'isin'::text
     LEFT JOIN market.issuer i ON i.issuer_id = s.issuer_id
     LEFT JOIN market.countries c ON c.iso2 = COALESCE(s.provider_country_iso2, s.country_iso2);
