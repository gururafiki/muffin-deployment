do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_market_cap_usd';
  if k = 'm' then execute 'drop materialized view if exists market.security_market_cap_usd cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_market_cap_usd cascade';
  end if;
end $$;
create view market.security_market_cap_usd as
SELECT s.security_id,
    s.market_cap AS market_cap_native,
    s.currency_code,
        CASE
            WHEN s.market_cap IS NULL THEN NULL::numeric
            WHEN s.currency_code = 'USD'::text THEN s.market_cap
            ELSE s.market_cap * fx.usd_per_unit
        END AS market_cap_usd,
    fx.as_of AS fx_as_of
   FROM market.security s
     LEFT JOIN market.fx_rate_current fx ON fx.currency_code = s.currency_code;
