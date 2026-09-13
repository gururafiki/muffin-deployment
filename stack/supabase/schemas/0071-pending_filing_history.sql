do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_filing_history';
  if k = 'm' then execute 'drop materialized view if exists market.pending_filing_history cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_filing_history cascade';
  end if;
end $$;
create view market.pending_filing_history as
SELECT s.security_id,
    s.cik,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.cik IS NOT NULL AND (s.filing_history_fetched_at IS NULL OR s.filing_history_fetched_at < (now() - '30 days'::interval))
  GROUP BY s.security_id, s.cik
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC, s.security_id;
