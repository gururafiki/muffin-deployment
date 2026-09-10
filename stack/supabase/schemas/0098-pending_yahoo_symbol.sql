do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_yahoo_symbol';
  if k = 'm' then execute 'drop materialized view if exists market.pending_yahoo_symbol cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_yahoo_symbol cascade';
  end if;
end $$;
create view market.pending_yahoo_symbol as
SELECT s.security_id,
    isin.value AS isin,
    s.country_iso2,
    COALESCE(ps.symbol, t.value) AS current_symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_identifier isin ON isin.security_id = s.security_id AND isin.kind_code = 'isin'::text
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND s.country_iso2 IS NOT NULL AND (s.industry_missing_at IS NOT NULL OR s.profile_missing_at IS NOT NULL OR s.performance_missing_at IS NOT NULL OR COALESCE(ps.symbol, t.value) IS NULL) AND (s.yahoo_symbol_missing_at IS NULL OR s.yahoo_symbol_missing_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, isin.value, s.country_iso2, (COALESCE(ps.symbol, t.value))
  ORDER BY (COALESCE(ps.symbol, t.value) IS NULL) DESC, (COALESCE(max(h.weight), 0::numeric)) DESC;
