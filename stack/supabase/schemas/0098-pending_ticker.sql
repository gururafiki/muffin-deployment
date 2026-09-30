do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_ticker';
  if k = 'm' then execute 'drop materialized view if exists market.pending_ticker cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_ticker cascade';
  end if;
end $$;
create view market.pending_ticker as
SELECT s.security_id,
    isin.value AS isin,
    s.name,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.security_identifier isin ON isin.security_id = s.security_id AND isin.kind_code = 'isin'::text
     LEFT JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE t.security_id IS NULL AND s.security_type_code = 'equity'::text AND (s.figi_missing_at IS NULL OR s.figi_missing_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, isin.value, s.name
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
