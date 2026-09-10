do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_price_targets';
  if k = 'm' then execute 'drop materialized view if exists market.pending_price_targets cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_price_targets cascade';
  end if;
end $$;
create view market.pending_price_targets as
SELECT s.security_id,
    t.value AS symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND (EXISTS ( SELECT 1
           FROM market.listing l
          WHERE l.security_id = s.security_id AND l.exch_code = 'US'::text)) AND (s.price_targets_fetched_at IS NULL OR s.price_targets_fetched_at < (now() - '7 days'::interval))
  GROUP BY s.security_id, t.value
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
