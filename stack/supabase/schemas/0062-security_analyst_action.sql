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
   FROM ( SELECT t.security_id,
            t.published_date,
            t.analyst_company,
            t.target_from,
            t.target_to,
            t.status,
            t.rating_change,
            t.source_code,
            t.fetched_at,
            t.published_at,
            t.currency_code,
            ds.priority,
            max(ds.priority) OVER (PARTITION BY t.security_id) AS best
           FROM market.security_price_target t
             JOIN market.data_source ds ON ds.code = t.source_code) ranked
  WHERE priority = best;
