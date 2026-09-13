do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_performance';
  if k = 'm' then execute 'drop materialized view if exists market.pending_performance cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_performance cascade';
  end if;
end $$;
create view market.pending_performance as
SELECT s.security_id,
    COALESCE(sym.symbol, ps.symbol, t.value) AS symbol,
    COALESCE(ps.symbol, t.value) AS fetch_symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     LEFT JOIN market.security_symbol sym ON sym.security_id = s.security_id
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     LEFT JOIN market.performance p ON p.scope = 'instrument'::text AND p.scope_id = COALESCE(sym.symbol, ps.symbol, t.value) AND p.stale_after > now()
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE p.scope_id IS NULL AND COALESCE(ps.symbol, t.value) IS NOT NULL AND (s.performance_missing_at IS NULL OR s.performance_missing_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, sym.symbol, ps.symbol, t.value
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
