do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_local_symbol';
  if k = 'm' then execute 'drop materialized view if exists market.pending_local_symbol cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_local_symbol cascade';
  end if;
end $$;
create view market.pending_local_symbol as
SELECT s.security_id,
    s.country_iso2,
    isin.value AS isin,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_identifier isin ON isin.security_id = s.security_id AND isin.kind_code = 'isin'::text
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE ps.security_id IS NULL AND s.security_type_code = 'equity'::text AND s.country_iso2 IS NOT NULL AND s.country_iso2 <> 'US'::text AND (EXISTS ( SELECT 1
           FROM market.exchange e
          WHERE e.country_iso2 = s.country_iso2)) AND (s.local_symbol_missing_at IS NULL OR s.local_symbol_missing_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, s.country_iso2, isin.value
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
