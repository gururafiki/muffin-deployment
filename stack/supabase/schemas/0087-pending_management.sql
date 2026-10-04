do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_management';
  if k = 'm' then execute 'drop materialized view if exists market.pending_management cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_management cascade';
  end if;
end $$;
create view market.pending_management as
SELECT s.security_id,
    COALESCE(ps.symbol, t.value) AS symbol,
    max(h.weight) AS best_weight
   FROM market.security s
     JOIN market.fund_holding_current h ON h.security_id = s.security_id
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
  WHERE s.security_type_code = 'equity'::text AND COALESCE(ps.symbol, t.value) IS NOT NULL AND (s.management_fetched_at IS NULL OR s.management_fetched_at < (now() - '180 days'::interval))
  GROUP BY s.security_id, (COALESCE(ps.symbol, t.value))
 HAVING max(h.weight) >= 0.5
  ORDER BY (max(h.weight)) DESC;
