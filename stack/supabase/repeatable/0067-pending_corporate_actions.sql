do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_corporate_actions';
  if k = 'm' then execute 'drop materialized view if exists market.pending_corporate_actions cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_corporate_actions cascade';
  end if;
end $$;
create view market.pending_corporate_actions as
SELECT s.security_id,
    t.value AS symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     JOIN market.security_symbol sym ON sym.security_id = s.security_id AND upper(sym.symbol) = upper(t.value)
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND (s.corporate_actions_missing_at IS NULL OR s.corporate_actions_missing_at < (now() - '30 days'::interval)) AND NOT (EXISTS ( SELECT 1
           FROM market.security_corporate_action a
          WHERE a.security_id = s.security_id AND a.as_of > (now() - '30 days'::interval)))
  GROUP BY s.security_id, t.value
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
