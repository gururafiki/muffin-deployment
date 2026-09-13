do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_peers';
  if k = 'm' then execute 'drop materialized view if exists market.security_peers cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_peers cascade';
  end if;
end $$;
create view market.security_peers as
SELECT s.security_id,
    p.security_id AS peer_id,
    p.name AS peer_name,
    p.symbol AS peer_symbol,
    p.market_cap_usd AS peer_market_cap_usd,
    s.market_cap_usd,
    s.sector_id,
    abs(ln(p.market_cap_usd / s.market_cap_usd)::double precision / ln(10::double precision)) AS size_distance
   FROM market.security_facets s
     JOIN market.security_facets p ON p.sector_id = s.sector_id AND p.security_id <> s.security_id
  WHERE s.sector_id IS NOT NULL AND s.market_cap_usd > 0::numeric AND p.market_cap_usd > 0::numeric;
