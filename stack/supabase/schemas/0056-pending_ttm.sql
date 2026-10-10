do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_ttm';
  if k = 'm' then execute 'drop materialized view if exists market.pending_ttm cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_ttm cascade';
  end if;
end $$;
create view market.pending_ttm as
SELECT q.security_id
   FROM ( SELECT m.security_id,
            max(m.fetched_at) AS newest_input
           FROM market.security_metric m
             JOIN market.metric mt ON mt.code = m.metric_code AND mt.is_flow
          WHERE (m.period_type = ANY (ARRAY['quarter'::text, 'annual'::text])) AND (m.source_code <> ALL (ARRAY['derived'::text, 'derived-q4'::text]))
          GROUP BY m.security_id) q
     LEFT JOIN market.ttm_derivation d ON d.security_id = q.security_id
  WHERE d.derived_at IS NULL OR d.derived_at < q.newest_input;
