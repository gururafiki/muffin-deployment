do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_metric_series';
  if k = 'm' then execute 'drop materialized view if exists market.security_metric_series cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_metric_series cascade';
  end if;
end $$;
create view market.security_metric_series as
WITH gapped AS (
         SELECT sm.security_id,
            sym.symbol,
            sm.metric_code,
            sm.period_type,
            sm.as_of,
            sm.value,
            sm.currency_code,
            sm.source_code,
            ds.priority,
                CASE
                    WHEN (sm.as_of - lag(sm.as_of) OVER (PARTITION BY sym.symbol, sm.security_id, sm.period_type ORDER BY sm.as_of)) <= 7 THEN 0
                    ELSE 1
                END AS starts_cluster
           FROM market.security_metric sm
             JOIN market.data_source ds ON ds.code = sm.source_code
             JOIN market.symbol_security sym ON sym.security_id = sm.security_id
        ), clustered AS (
         SELECT g.security_id,
            g.symbol,
            g.metric_code,
            g.period_type,
            g.as_of,
            g.value,
            g.currency_code,
            g.source_code,
            g.priority,
            sum(g.starts_cluster) OVER (PARTITION BY g.symbol, g.security_id, g.period_type ORDER BY g.as_of) AS period_group,
            count(*) OVER (PARTITION BY g.symbol, g.security_id, g.period_type, g.priority, g.as_of) AS rows_on_date
           FROM gapped g
        ), anchored AS (
         SELECT c.security_id,
            c.symbol,
            c.metric_code,
            c.period_type,
            c.as_of,
            c.value,
            c.currency_code,
            c.source_code,
            c.priority,
            c.period_group,
            first_value(c.as_of) OVER (PARTITION BY c.symbol, c.security_id, c.period_type, c.period_group ORDER BY c.priority DESC, c.rows_on_date DESC, c.as_of DESC) AS period_as_of
           FROM clustered c
        )
 SELECT DISTINCT ON (a.symbol, a.security_id, a.metric_code, a.period_type, a.period_group) a.symbol,
    a.security_id,
    a.metric_code,
    m.name AS metric_name,
    m.category,
    m.unit,
    m.is_derived,
    a.period_type,
    a.period_as_of AS as_of,
    a.value,
    COALESCE(a.currency_code, s.reporting_currency) AS currency_code,
    a.source_code
   FROM anchored a
     JOIN market.metric m ON m.code = a.metric_code
     JOIN market.security s ON s.security_id = a.security_id
  ORDER BY a.symbol, a.security_id, a.metric_code, a.period_type, a.period_group, a.priority DESC, (a.as_of = a.period_as_of) DESC, a.as_of DESC;
