do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_wikidata';
  if k = 'm' then execute 'drop materialized view if exists market.pending_wikidata cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_wikidata cascade';
  end if;
end $$;
create view market.pending_wikidata as
SELECT s.security_id,
    i.value AS isin,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_identifier i ON i.security_id = s.security_id AND i.kind_code = 'isin'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND (s.wikidata_missing_at IS NULL OR s.wikidata_missing_at < (now() - '30 days'::interval)) AND NOT (EXISTS ( SELECT 1
           FROM market.security_taxonomy st
          WHERE st.security_id = s.security_id AND st.source_code = 'wikidata'::text))
  GROUP BY s.security_id, i.value
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC, s.security_id;
