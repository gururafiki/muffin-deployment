do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'directory_query';
  if k = 'm' then execute 'drop materialized view if exists market.directory_query cascade';
  elsif k = 'v' then execute 'drop view if exists market.directory_query cascade';
  end if;
end $$;
create view market.directory_query as
SELECT (e.exch_code || '.'::text) || t.key_suffix AS query_key,
    e.exch_code AS exch_code_asked,
    e.exch_code AS files_under,
    t.security_type2,
    false AS maps_to_composite
   FROM market.exchange e
     CROSS JOIN market.directory_type t
  WHERE e.enabled AND t.enabled
UNION ALL
 SELECT a.query_key,
    a.exch_code_asked,
    a.files_under,
    a.security_type2,
    true AS maps_to_composite
   FROM market.directory_alias a
     JOIN market.directory_type t ON t.security_type2 = a.security_type2
     JOIN market.exchange e ON e.exch_code = a.files_under
  WHERE a.enabled AND t.enabled AND e.enabled;
