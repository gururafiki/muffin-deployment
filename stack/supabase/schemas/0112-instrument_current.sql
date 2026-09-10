do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'instrument_current';
  if k = 'm' then execute 'drop materialized view if exists market.instrument_current cascade';
  elsif k = 'v' then execute 'drop view if exists market.instrument_current cascade';
  end if;
end $$;
create view market.instrument_current as
SELECT i.symbol,
    COALESCE(i.name, s.name) AS name,
    i.asset_type,
    i.priced,
    i.sort_order,
    i.price_symbol,
    i.security_id,
    COALESCE(s.sector_id, i.sector_id) AS sector_id,
    COALESCE(s.industry, i.industry) AS industry,
    COALESCE(s.country_name, i.country) AS country,
    COALESCE(s.market_cap, i.market_cap) AS market_cap,
    COALESCE(s.currency_code, i.currency) AS currency,
    i.provider_sector,
    i.updated_at
   FROM market.instruments i
     LEFT JOIN market.security_current s ON s.security_id = i.security_id;
