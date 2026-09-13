do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_share_stats';
  if k = 'm' then execute 'drop materialized view if exists market.pending_share_stats cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_share_stats cascade';
  end if;
end $$;
create view market.pending_share_stats as
SELECT s.security_id,
    sym.symbol,
    COALESCE(ps.symbol, sym.symbol) AS fetch_symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_symbol sym ON sym.security_id = s.security_id
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.security_share_stats st ON st.security_id = s.security_id AND st.fetched_at > (now() - '7 days'::interval)
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND st.security_id IS NULL AND (s.share_stats_missing_at IS NULL OR s.share_stats_missing_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, sym.symbol, (COALESCE(ps.symbol, sym.symbol))
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC, s.security_id;
