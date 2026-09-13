do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_prices';
  if k = 'm' then execute 'drop materialized view if exists market.pending_prices cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_prices cascade';
  end if;
end $$;
create view market.pending_prices as
SELECT s.security_id,
    sym.symbol,
    COALESCE(ps.symbol, sym.symbol) AS fetch_symbol,
    p.last_date,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_symbol sym ON sym.security_id = s.security_id
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN LATERAL ( SELECT max(sp.date) AS last_date
           FROM market.security_price sp
          WHERE sp.security_id = s.security_id) p ON true
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND (p.last_date IS NULL OR p.last_date < ((now() AT TIME ZONE 'utc'::text)::date - 2)) AND (s.prices_missing_at IS NULL OR s.prices_missing_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, sym.symbol, ps.symbol, p.last_date
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
