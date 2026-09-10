do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_kr_history';
  if k = 'm' then execute 'drop materialized view if exists market.pending_kr_history cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_kr_history cascade';
  end if;
end $$;
create view market.pending_kr_history as
SELECT sf.security_id,
    sf.filer_id,
    COALESCE(max(h.weight), 0::numeric) AS best_weight,
    sf.history_walked_at
   FROM market.security_filer sf
     JOIN market.security s ON s.security_id = sf.security_id
     LEFT JOIN market.fund_holding_current h ON h.security_id = sf.security_id
  WHERE sf.source_code = 'dart'::text AND (sf.history_walked_at IS NULL OR sf.history_walked_at < (now() - '90 days'::interval))
  GROUP BY sf.security_id, sf.filer_id, sf.history_walked_at
  ORDER BY (sf.history_walked_at IS NOT NULL), (COALESCE(max(h.weight), 0::numeric)) DESC, sf.security_id;
