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
    c.native AS market_cap_native,
    c.currency AS currency_code,
        CASE
            WHEN c.native IS NULL THEN NULL::numeric
            WHEN c.currency = 'USD'::text THEN c.native
            ELSE c.native * fx.usd_per_unit
        END AS market_cap_usd,
    fx.as_of AS fx_as_of,
    c.source AS cap_source
   FROM market.security s
     LEFT JOIN market.security_fundamentals f ON f.security_id = s.security_id
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN f.market_cap IS NOT NULL THEN f.market_cap
                    ELSE s.market_cap
                END AS native,
                CASE
                    WHEN f.market_cap IS NOT NULL THEN f.market_cap_currency
                    ELSE s.currency_code
                END AS currency,
                CASE
                    WHEN f.market_cap IS NOT NULL THEN 'fundamentals'::text
                    WHEN s.market_cap IS NOT NULL THEN 'security'::text
                    ELSE NULL::text
                END AS source) c
     LEFT JOIN market.fx_rate_current fx ON fx.currency_code = c.currency;
