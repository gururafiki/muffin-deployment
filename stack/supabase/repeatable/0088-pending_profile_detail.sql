do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_profile_detail';
  if k = 'm' then execute 'drop materialized view if exists market.pending_profile_detail cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_profile_detail cascade';
  end if;
end $$;
create view market.pending_profile_detail as
SELECT s.security_id,
    COALESCE(ps.symbol, t.value) AS symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     LEFT JOIN market.security_profile p ON p.security_id = s.security_id
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE p.security_id IS NULL AND s.security_type_code = 'equity'::text AND COALESCE(ps.symbol, t.value) IS NOT NULL AND (s.profile_detail_missing_at IS NULL OR s.profile_detail_missing_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, (COALESCE(ps.symbol, t.value))
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
