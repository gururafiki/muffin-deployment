do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_insider';
  if k = 'm' then execute 'drop materialized view if exists market.pending_insider cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_insider cascade';
  end if;
end $$;
create view market.pending_insider as
SELECT s.security_id,
    s.cik,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND s.cik IS NOT NULL AND (s.insider_fetched_at IS NULL OR s.insider_fetched_at < (now() - '7 days'::interval))
  GROUP BY s.security_id, s.cik
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
