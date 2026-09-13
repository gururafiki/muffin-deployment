do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_daily_history';
  if k = 'm' then execute 'drop materialized view if exists market.pending_daily_history cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_daily_history cascade';
  end if;
end $$;
create view market.pending_daily_history as
SELECT s.security_id,
    sym.symbol,
    COALESCE(ps.symbol, sym.symbol) AS fetch_symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_symbol sym ON sym.security_id = s.security_id
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND s.daily_history_from IS NULL AND (s.daily_history_missing_at IS NULL OR s.daily_history_missing_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, sym.symbol, (COALESCE(ps.symbol, sym.symbol))
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC, s.security_id;
