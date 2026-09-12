do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'performance';
  if k = 'm' then execute 'drop materialized view if exists market.performance cascade';
  elsif k = 'v' then execute 'drop view if exists market.performance cascade';
  end if;
end $$;
create view market.performance as
SELECT 'instrument'::text AS scope,
    sym.symbol AS scope_id,
    sr.period_code AS period,
    sr.price_return_pct AS change_pct,
    sr.as_of::timestamp with time zone AS as_of,
    (sr.as_of + '1 day'::interval)::timestamp with time zone AS stale_after,
    sr.source_code AS source,
    sr.total_return_pct
   FROM market.security_return sr
     JOIN market.security_symbol sym ON sym.security_id = sr.security_id
UNION ALL
 SELECT split_part(ir.index_code, ':'::text, 1) AS scope,
    substr(ir.index_code, POSITION((':'::text) IN (ir.index_code)) + 1) AS scope_id,
    ir.period_code AS period,
    ir.price_return_pct AS change_pct,
    ir.as_of::timestamp with time zone AS as_of,
    (ir.as_of + '1 day'::interval)::timestamp with time zone AS stale_after,
    ir.source_code AS source,
    ir.total_return_pct
   FROM market.index_return ir;
