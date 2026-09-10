do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_cn_filings';
  if k = 'm' then execute 'drop materialized view if exists market.pending_cn_filings cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_cn_filings cascade';
  end if;
end $$;
create view market.pending_cn_filings as
SELECT s.security_id,
    l.symbol,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.security s
     JOIN market.listing l ON l.security_id = s.security_id
     LEFT JOIN market.security_filer sf ON sf.security_id = s.security_id AND sf.source_code = 'cninfo'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND s.country_iso2 = 'CN'::text AND l.symbol ~ '^[0-9]{6}$'::text AND (sf.history_walked_at IS NULL OR sf.history_walked_at < (now() - '180 days'::interval))
  GROUP BY s.security_id, l.symbol
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC, l.symbol;
