do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_currency';
  if k = 'm' then execute 'drop materialized view if exists market.security_currency cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_currency cascade';
  end if;
end $$;
create view market.security_currency as
SELECT s.security_id,
    COALESCE(ps.quote_currency, pl.currency_code, s.currency_code) AS currency_code,
        CASE
            WHEN ps.quote_currency IS NOT NULL THEN 'price'::text
            WHEN pl.currency_code IS NOT NULL THEN 'listing'::text
            WHEN s.currency_code IS NOT NULL THEN 'security'::text
            ELSE NULL::text
        END AS source,
    pl.exch_code AS venue
   FROM market.security s
     LEFT JOIN market.listing pl ON pl.security_id = s.security_id AND pl.is_primary
     LEFT JOIN market.security_price_span ps ON ps.security_id = s.security_id;
