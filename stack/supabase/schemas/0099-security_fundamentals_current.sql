do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_fundamentals_current';
  if k = 'm' then execute 'drop materialized view if exists market.security_fundamentals_current cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_fundamentals_current cascade';
  end if;
end $$;
create view market.security_fundamentals_current as
SELECT sym.symbol,
    f.security_id,
    f.source_code,
    f.as_of,
    f.pe_ratio,
    f.forward_pe,
    f.peg_ratio,
    f.price_to_book,
    f.profit_margin,
    f.gross_margin,
    f.operating_margin,
    f.return_on_equity,
    f.revenue_growth,
    f.debt_to_equity,
    f.dividend_yield,
    f.beta,
    f.enterprise_value,
    f.raw,
    s.currency_code
   FROM market.security_fundamentals f
     JOIN market.security_symbol sym ON sym.security_id = f.security_id
     JOIN market.security s ON s.security_id = f.security_id;
