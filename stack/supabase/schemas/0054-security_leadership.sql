do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_leadership';
  if k = 'm' then execute 'drop materialized view if exists market.security_leadership cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_leadership cascade';
  end if;
end $$;
create view market.security_leadership as
SELECT o.security_id,
    o.name,
    o.title,
    o.pay,
    o.age,
    o.fiscal_year,
    o.title ~~* '%chief executive%'::text OR o.title ~~* '%CEO%'::text AS is_ceo,
        CASE
            WHEN s.reporting_currency IS NOT NULL THEN s.reporting_currency
            WHEN s.currency_code IS NULL THEN NULL::text
            WHEN s.currency_code <> 'USD'::text THEN s.currency_code
            WHEN COALESCE(s.provider_country_iso2, s.country_iso2) = 'US'::text THEN s.currency_code
            ELSE NULL::text
        END AS pay_currency
   FROM market.security_officer o
     JOIN market.security s ON s.security_id = o.security_id;
