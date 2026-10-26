do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_recent_filings';
  if k = 'm' then execute 'drop materialized view if exists market.security_recent_filings cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_recent_filings cascade';
  end if;
end $$;
create view market.security_recent_filings as
SELECT f.security_id,
    f.accession_number,
    f.filing_date,
    f.report_date,
    f.report_type,
    f.report_url,
    f.filing_detail_url,
        CASE
            WHEN ff.kind = 'accounts'::text AND ff.is_annual THEN 'annual'::text
            WHEN ff.kind = 'accounts'::text THEN 'interim'::text
            ELSE 'event'::text
        END AS kind
   FROM market.security_filing f
     LEFT JOIN market.filing_form ff ON ff.source_code = 'sec'::text AND ff.form_code = f.report_type;
