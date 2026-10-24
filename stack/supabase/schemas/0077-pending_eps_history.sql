do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_eps_history';
  if k = 'm' then execute 'drop materialized view if exists market.pending_eps_history cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_eps_history cascade';
  end if;
end $$;
create view market.pending_eps_history as
SELECT s.security_id,
    t.value AS symbol,
    max(h.weight) AS best_weight
   FROM market.security s
     JOIN market.fund_holding_current h ON h.security_id = s.security_id
     JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
  WHERE s.security_type_code = 'equity'::text AND t.value !~~ '%.%'::text AND (EXISTS ( SELECT 1
           FROM market.listing l
          WHERE l.security_id = s.security_id AND l.exch_code = 'US'::text)) AND (s.eps_history_fetched_at IS NULL OR s.eps_history_fetched_at < (now() - '90 days'::interval))
  GROUP BY s.security_id, t.value
 HAVING max(h.weight) >= 1.0
  ORDER BY (max(h.weight)) DESC;
