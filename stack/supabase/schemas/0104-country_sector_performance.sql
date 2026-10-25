do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'country_sector_performance';
  if k = 'm' then execute 'drop materialized view if exists market.country_sector_performance cascade';
  elsif k = 'v' then execute 'drop view if exists market.country_sector_performance cascade';
  end if;
end $$;
create view market.country_sector_performance as
WITH constituent AS (
         SELECT DISTINCT ON (s.security_id) s.security_id,
            COALESCE(s.provider_country_iso2, s.country_iso2) AS country_iso2,
            tn.code AS sector_id,
            sym.symbol,
            h.weight,
            tf.symbol AS fund_symbol
           FROM market.security s
             JOIN market.security_taxonomy st ON st.security_id = s.security_id
             JOIN market.taxonomy_node tn ON tn.node_id = st.node_id AND tn.taxonomy_id = 'muffin'::text AND tn.level = 1
             JOIN market.data_source ds ON ds.code = st.source_code
             JOIN market.security_symbol sym ON sym.security_id = s.security_id
             JOIN market.fund_holding_current h ON h.security_id = s.security_id
             JOIN market.security_identifier fi ON fi.security_id = h.fund_id AND fi.kind_code = 'ticker'::text
             JOIN market.tracked_fund tf ON tf.symbol = fi.value AND tf.kind = 'country'::text AND tf.represents_code = COALESCE(s.provider_country_iso2, s.country_iso2)
          WHERE COALESCE(s.provider_country_iso2, s.country_iso2) IS NOT NULL AND s.security_type_code = 'equity'::text AND h.weight > 0::numeric AND sym.symbol IS NOT NULL
          ORDER BY s.security_id, ds.priority DESC, st.as_of DESC
        )
 SELECT c.country_iso2,
    c.sector_id,
    p.period,
    round(sum(c.weight * p.change_pct) / NULLIF(sum(c.weight), 0::numeric), 4) AS change_pct,
    round(sum(c.weight * p.total_return_pct) FILTER (WHERE p.total_return_pct IS NOT NULL) / NULLIF(sum(c.weight) FILTER (WHERE p.total_return_pct IS NOT NULL), 0::numeric), 4) AS total_return_pct,
    count(*) AS constituents,
    count(*) FILTER (WHERE p.total_return_pct IS NOT NULL) AS total_return_constituents,
    round(sum(c.weight), 4) AS weight_covered,
    min(c.fund_symbol) AS fund_symbol,
    max(p.as_of) AS as_of
   FROM constituent c
     JOIN market.performance p ON p.scope = 'instrument'::text AND p.scope_id = c.symbol
  GROUP BY c.country_iso2, c.sector_id, p.period;
