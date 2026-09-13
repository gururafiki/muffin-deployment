do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_symbol';
  if k = 'm' then execute 'drop materialized view if exists market.security_symbol cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_symbol cascade';
  end if;
end $$;
create view market.security_symbol as
SELECT s.security_id,
    COALESCE(( SELECT l.provider_symbol
           FROM market.listing l
          WHERE l.security_id = s.security_id AND l.is_primary
         LIMIT 1), ps.symbol, t.value) AS symbol
   FROM market.security s
     LEFT JOIN LATERAL ( SELECT i.value
           FROM market.security_identifier i
          WHERE i.security_id = s.security_id AND i.kind_code = 'ticker'::text
          ORDER BY i.value
         LIMIT 1) t ON true
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
  WHERE COALESCE(( SELECT l.provider_symbol
           FROM market.listing l
          WHERE l.security_id = s.security_id AND l.is_primary
         LIMIT 1), ps.symbol, t.value) IS NOT NULL;
