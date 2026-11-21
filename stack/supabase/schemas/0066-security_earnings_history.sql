do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_earnings_history';
  if k = 'm' then execute 'drop materialized view if exists market.security_earnings_history cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_earnings_history cascade';
  end if;
end $$;
create view market.security_earnings_history as
WITH per_source AS (
         SELECT security_eps_history.security_id,
            security_eps_history.source_code,
            count(*) AS quarters,
            max(security_eps_history.period_ending) AS newest,
            max(max(security_eps_history.period_ending)) OVER (PARTITION BY security_eps_history.security_id) AS newest_any
           FROM market.security_eps_history
          GROUP BY security_eps_history.security_id, security_eps_history.source_code
        ), chosen AS (
         SELECT DISTINCT ON (s.security_id) s.security_id,
            s.source_code
           FROM per_source s
             JOIN market.data_source ds ON ds.code = s.source_code
          ORDER BY s.security_id, (s.newest >= (s.newest_any - 100)) DESC, s.quarters DESC, ds.priority DESC, s.source_code
        )
 SELECT h.security_id,
    h.period_ending,
    h.reported_date,
    h.eps_actual AS actual,
    h.eps_estimated AS estimate,
    h.eps_actual - h.eps_estimated AS surprise,
        CASE
            WHEN h.eps_estimated <> 0::numeric THEN round((h.eps_actual - h.eps_estimated) / abs(h.eps_estimated) * 100::numeric, 2)
            ELSE NULL::numeric
        END AS surprise_pct,
    h.eps_actual >= h.eps_estimated AS beat,
    h.source_code,
    h.as_of
   FROM market.security_eps_history h
     JOIN chosen c ON c.security_id = h.security_id AND c.source_code = h.source_code;
