do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'macro_current';
  if k = 'm' then execute 'drop materialized view if exists market.macro_current cascade';
  elsif k = 'v' then execute 'drop view if exists market.macro_current cascade';
  end if;
end $$;
create view market.macro_current as
SELECT DISTINCT ON (i.code, o.dimension) i.code,
    i.name,
    i.category,
    i.country_iso2,
    i.unit,
    i.frequency,
    o.dimension,
        CASE
            WHEN i.value_is_fraction THEN round(o.value * 100::numeric, 4)
            ELSE o.value
        END AS value,
    o.as_of,
    o.fetched_at
   FROM market.macro_indicator i
     JOIN market.macro_observation o ON o.indicator_code = i.code
  WHERE i.enabled
  ORDER BY i.code, o.dimension, o.as_of DESC;
