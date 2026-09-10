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
SELECT DISTINCT ON (symbol, grain, date) symbol,
    date,
    close,
    grain
   FROM ( SELECT ss.symbol,
            sp.date,
            sp.close,
            sp.grain,
            1 AS priority
           FROM market.security_price sp
             JOIN market.symbol_security ss ON ss.security_id = sp.security_id
        UNION ALL
         SELECT p.symbol,
            p.date,
            p.close,
            'daily'::text AS grain,
            2 AS priority
           FROM market.prices p) x
  ORDER BY symbol, grain, date, priority;
