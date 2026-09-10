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
SELECT security_id,
    accession_number,
    filing_date,
    report_date,
    report_type,
    report_url,
    filing_detail_url,
        CASE
            WHEN report_type = ANY (ARRAY['10-K'::text, '10-K/A'::text, '20-F'::text, '20-F/A'::text]) THEN 'annual'::text
            WHEN report_type = ANY (ARRAY['10-Q'::text, '10-Q/A'::text, '6-K'::text, '6-K/A'::text]) THEN 'interim'::text
            ELSE 'event'::text
        END AS kind
   FROM market.security_filing f;
