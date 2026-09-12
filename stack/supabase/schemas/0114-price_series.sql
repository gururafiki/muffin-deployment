do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'price_series';
  if k = 'm' then execute 'drop materialized view if exists market.price_series cascade';
  elsif k = 'v' then execute 'drop view if exists market.price_series cascade';
  end if;
end $$;
create view market.price_series as
SELECT ss.symbol,
    pb.trade_date AS date,
    pb.close,
    'daily'::text AS grain
   FROM market.price_bar pb
     JOIN market.symbol_security ss ON ss.security_id = pb.security_id
UNION ALL
 SELECT w.symbol,
    w.date,
    w.close,
    'weekly'::text AS grain
   FROM ( SELECT DISTINCT ON (ss.symbol, (date_trunc('week'::text, pb.trade_date::timestamp with time zone))) ss.symbol,
            pb.trade_date AS date,
            pb.close
           FROM market.price_bar pb
             JOIN market.symbol_security ss ON ss.security_id = pb.security_id
          ORDER BY ss.symbol, (date_trunc('week'::text, pb.trade_date::timestamp with time zone)), pb.trade_date DESC) w;
