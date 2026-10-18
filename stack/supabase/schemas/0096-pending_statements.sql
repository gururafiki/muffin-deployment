do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_statements';
  if k = 'm' then execute 'drop materialized view if exists market.pending_statements cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_statements cascade';
  end if;
end $$;
create view market.pending_statements as
SELECT s.security_id,
    COALESCE(ps.symbol, t.value) AS symbol,
    us.symbol AS us_ticker,
        CASE
            WHEN NOT a.has_any THEN 'missing'::text
            ELSE 'no_sec'::text
        END AS want,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN LATERAL ( SELECT l.symbol
           FROM market.listing l
             JOIN market.exchange e ON e.exch_code = l.exch_code
          WHERE l.security_id = s.security_id AND e.country_iso2 = 'US'::text AND l.symbol IS NOT NULL
          ORDER BY l.is_primary DESC, l.symbol
         LIMIT 1) us ON true
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     CROSS JOIN LATERAL ( SELECT (EXISTS ( SELECT 1
                   FROM market.security_statement x
                  WHERE x.security_id = s.security_id)) AS has_any) a
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND s.cik IS NOT NULL AND (s.statement_currency_missing_at IS NULL OR s.statement_currency_missing_at < (now() - '30 days'::interval)) AND NOT (EXISTS ( SELECT 1
           FROM market.security_statement x
          WHERE x.security_id = s.security_id AND x.source_code = 'sec'::text))
  GROUP BY s.security_id, (COALESCE(ps.symbol, t.value)), us.symbol, a.has_any
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC, s.security_id;
