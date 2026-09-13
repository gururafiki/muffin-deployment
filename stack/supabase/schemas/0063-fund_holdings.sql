do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'fund_holdings';
  if k = 'm' then execute 'drop materialized view if exists market.fund_holdings cascade';
  elsif k = 'v' then execute 'drop view if exists market.fund_holdings cascade';
  end if;
end $$;
create view market.fund_holdings as
SELECT fi.value AS fund_symbol,
    h.security_id,
    s.name,
    sym.symbol,
    s.country_iso2,
    s.security_type_code,
    s.currency_code,
    h.weight,
    h.market_value,
    h.as_of
   FROM market.fund_holding_current h
     JOIN market.security_identifier fi ON fi.security_id = h.fund_id AND fi.kind_code = 'ticker'::text
     JOIN market.security s ON s.security_id = h.security_id
     LEFT JOIN market.security_symbol sym ON sym.security_id = h.security_id
  WHERE h.security_id <> h.fund_id;
