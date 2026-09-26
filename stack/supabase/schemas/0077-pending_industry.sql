do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_industry';
  if k = 'm' then execute 'drop materialized view if exists market.pending_industry cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_industry cascade';
  end if;
end $$;
create view market.pending_industry as
SELECT s.security_id,
    COALESCE(ps.symbol, t.value) AS symbol,
    sec_n.code AS sector_id,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_taxonomy sec_st ON sec_st.security_id = s.security_id
     JOIN market.taxonomy_node sec_n ON sec_n.node_id = sec_st.node_id AND sec_n.taxonomy_id = 'muffin'::text AND sec_n.level = 1
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM market.security_taxonomy ind_st
             JOIN market.taxonomy_node ind_n ON ind_n.node_id = ind_st.node_id AND ind_n.taxonomy_id = 'muffin'::text AND ind_n.level = 2
          WHERE ind_st.security_id = s.security_id)) AND COALESCE(ps.symbol, t.value) IS NOT NULL AND (s.industry_missing_at IS NULL OR s.industry_missing_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, (COALESCE(ps.symbol, t.value)), sec_n.code
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
