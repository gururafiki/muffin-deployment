do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'fx_rate_current';
  if k = 'm' then execute 'drop materialized view if exists market.fx_rate_current cascade';
  elsif k = 'v' then execute 'drop view if exists market.fx_rate_current cascade';
  end if;
end $$;
create view market.fx_rate_current as
SELECT DISTINCT ON (currency_code) currency_code,
    as_of,
    usd_per_unit,
    source_code,
    derived_from
   FROM market.fx_rate
  ORDER BY currency_code, as_of DESC;
