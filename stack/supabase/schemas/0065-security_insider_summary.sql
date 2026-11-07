do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_insider_summary';
  if k = 'm' then execute 'drop materialized view if exists market.security_insider_summary cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_insider_summary cascade';
  end if;
end $$;
create view market.security_insider_summary as
SELECT security_id,
    count(*) FILTER (WHERE direction = 'Acquisition'::text) AS buys,
    count(*) FILTER (WHERE direction = 'Disposition'::text) AS sells,
    count(DISTINCT owner_name) FILTER (WHERE direction = 'Acquisition'::text) AS buyers,
    count(DISTINCT owner_name) FILTER (WHERE direction = 'Disposition'::text) AS sellers,
    COALESCE(sum(shares) FILTER (WHERE direction = 'Acquisition'::text), 0::numeric) - COALESCE(sum(shares) FILTER (WHERE direction = 'Disposition'::text), 0::numeric) AS net_shares,
    max(transaction_date) AS latest,
    count(*) AS trades
   FROM market.insider_trade t
  WHERE transaction_date >= (CURRENT_DATE - 90) AND accession_number IS NOT NULL AND (form_type IS DISTINCT FROM '4'::text OR NOT (EXISTS ( SELECT 1
           FROM market.insider_trade a
          WHERE a.security_id = t.security_id AND a.owner_cik = t.owner_cik AND a.transaction_date = t.transaction_date AND a.is_derivative = t.is_derivative AND a.transaction_code = t.transaction_code AND a.form_type = '4/A'::text AND a.filing_date >= t.filing_date)))
  GROUP BY security_id;
