do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'venue_currency';
  if k = 'm' then execute 'drop materialized view if exists market.venue_currency cascade';
  elsif k = 'v' then execute 'drop view if exists market.venue_currency cascade';
  end if;
end $$;
create view market.venue_currency as
WITH quoted AS (
         SELECT SUBSTRING(sym.symbol FROM POSITION(('.'::text) IN (sym.symbol))) AS suffix,
            s.currency_code
           FROM market.security s
             JOIN market.security_symbol sym ON sym.security_id = s.security_id
          WHERE s.currency_code IS NOT NULL AND POSITION(('.'::text) IN (sym.symbol)) > 0
        ), tallied AS (
         SELECT quoted.suffix,
            quoted.currency_code,
            count(*) AS n,
            sum(count(*)) OVER (PARTITION BY quoted.suffix) AS venue_total
           FROM quoted
          GROUP BY quoted.suffix, quoted.currency_code
        )
 SELECT DISTINCT ON (suffix) suffix,
    currency_code AS quote_currency,
    n AS agreeing,
    venue_total AS securities
   FROM tallied
  WHERE venue_total >= 5::numeric AND (n::numeric / venue_total) > 0.60
  ORDER BY suffix, n DESC;
