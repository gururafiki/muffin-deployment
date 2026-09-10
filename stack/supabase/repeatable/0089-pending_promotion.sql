do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_promotion';
  if k = 'm' then execute 'drop materialized view if exists market.pending_promotion cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_promotion cascade';
  end if;
end $$;
create view market.pending_promotion as
SELECT l.figi,
    l.composite_figi,
    l.exch_code,
    l.ticker,
    l.name,
    l.country_iso2,
    l.provider_symbol,
    e.promotion_tier,
    e.preference
   FROM market.untracked_listing l
     JOIN market.exchange e ON e.exch_code = l.exch_code
  WHERE e.promotion_enabled AND e.enabled AND NOT (EXISTS ( SELECT 1
           FROM market.security s
          WHERE upper(s.name) = upper(l.name)))
  ORDER BY e.promotion_tier, e.preference, l.name;
