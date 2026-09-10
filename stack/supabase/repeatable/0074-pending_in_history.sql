do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_in_history';
  if k = 'm' then execute 'drop materialized view if exists market.pending_in_history cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_in_history cascade';
  end if;
end $$;
create view market.pending_in_history as
SELECT s.security_id,
    COALESCE(sf.filer_id, l.symbol) AS symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.listing l ON l.security_id = s.security_id
     JOIN market.exchange e ON e.exch_code = l.exch_code
     LEFT JOIN market.security_filer sf ON sf.security_id = s.security_id AND sf.source_code = 'nse'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND s.country_iso2 = 'IN'::text AND e.country_iso2 = 'IN'::text AND l.symbol IS NOT NULL AND (sf.history_walked_at IS NULL OR sf.history_walked_at < (now() - '90 days'::interval))
  GROUP BY s.security_id, sf.filer_id, l.symbol
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC, (COALESCE(sf.filer_id, l.symbol));
