do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_analyst_action';
  if k = 'm' then execute 'drop materialized view if exists market.security_analyst_action cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_analyst_action cascade';
  end if;
end $$;
create view market.security_analyst_action as
SELECT security_id,
    published_at,
    published_date,
    analyst_company,
    target_from,
    target_to,
    currency_code,
    status,
    rating_change,
    source_code
   FROM market.security_price_target t
  WHERE NOT (EXISTS ( SELECT 1
           FROM market.security_price_target o
          WHERE o.security_id = t.security_id AND o.published_date = t.published_date AND lower(o.analyst_company) = lower(t.analyst_company) AND market.source_priority(o.source_code) > market.source_priority(t.source_code)));
