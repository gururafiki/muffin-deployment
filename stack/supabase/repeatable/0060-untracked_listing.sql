do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'untracked_listing';
  if k = 'm' then execute 'drop materialized view if exists market.untracked_listing cascade';
  elsif k = 'v' then execute 'drop view if exists market.untracked_listing cascade';
  end if;
end $$;
create view market.untracked_listing as
SELECT figi,
    composite_figi,
    exch_code,
    ticker,
    name,
    country_iso2,
    provider_symbol
   FROM market.exchange_listing l
  WHERE name IS NOT NULL AND NOT (EXISTS ( SELECT 1
           FROM market.security_identifier si
          WHERE si.kind_code = 'figi'::text AND si.value = l.composite_figi)) AND NOT (EXISTS ( SELECT 1
           FROM market.security_provider_symbol ps
          WHERE upper(ps.symbol) = upper(l.provider_symbol))) AND NOT (EXISTS ( SELECT 1
           FROM market.security_identifier ti
          WHERE ti.kind_code = 'ticker'::text AND upper(ti.value) = upper(l.provider_symbol)));
