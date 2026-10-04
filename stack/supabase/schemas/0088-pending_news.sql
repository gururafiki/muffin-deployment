do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_news';
  if k = 'm' then execute 'drop materialized view if exists market.pending_news cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_news cascade';
  end if;
end $$;
create view market.pending_news as
SELECT s.security_id,
    sym.symbol,
    COALESCE(ps.symbol, sym.symbol) AS fetch_symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_symbol sym ON sym.security_id = s.security_id
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND (s.news_fetched_at IS NULL OR s.news_fetched_at < (now() - '7 days'::interval))
  GROUP BY s.security_id, sym.symbol, (COALESCE(ps.symbol, sym.symbol))
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC, s.security_id;
