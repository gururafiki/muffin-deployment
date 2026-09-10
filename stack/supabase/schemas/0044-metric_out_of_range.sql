do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'metric_out_of_range';
  if k = 'm' then execute 'drop materialized view if exists market.metric_out_of_range cascade';
  elsif k = 'v' then execute 'drop view if exists market.metric_out_of_range cascade';
  end if;
end $$;
create view market.metric_out_of_range as
SELECT m.code AS metric_code,
    count(*) AS n
   FROM market.security_metric sm
     JOIN market.metric m ON m.code = sm.metric_code
  WHERE m.min_plausible IS NOT NULL AND sm.value < m.min_plausible OR m.max_plausible IS NOT NULL AND sm.value > m.max_plausible
  GROUP BY m.code;
