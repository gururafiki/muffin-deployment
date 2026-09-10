do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'symbol_security';
  if k = 'm' then execute 'drop materialized view if exists market.symbol_security cascade';
  elsif k = 'v' then execute 'drop view if exists market.symbol_security cascade';
  end if;
end $$;
create materialized view market.symbol_security as
SELECT s.security_id,
    sym.symbol
   FROM market.security s
     JOIN market.security_symbol sym ON sym.security_id = s.security_id
  WHERE sym.symbol IS NOT NULL;
