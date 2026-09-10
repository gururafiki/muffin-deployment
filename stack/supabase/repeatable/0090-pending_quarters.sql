do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_quarters';
  if k = 'm' then execute 'drop materialized view if exists market.pending_quarters cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_quarters cascade';
  end if;
end $$;
create view market.pending_quarters as
SELECT s.security_id,
    COALESCE(ps.symbol, t.value) AS symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND s.cik IS NULL AND COALESCE(ps.symbol, t.value) IS NOT NULL AND (s.quarters_missing_at IS NULL OR s.quarters_missing_at < (now() - '30 days'::interval)) AND (EXISTS ( SELECT 1
           FROM market.security_statement a
          WHERE a.security_id = s.security_id AND a.period_type = 'annual'::text)) AND NOT (EXISTS ( SELECT 1
           FROM market.security_statement q
          WHERE q.security_id = s.security_id AND q.period_type = 'quarter'::text))
  GROUP BY s.security_id, (COALESCE(ps.symbol, t.value))
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
