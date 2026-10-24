do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_in_segments';
  if k = 'm' then execute 'drop materialized view if exists market.pending_in_segments cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_in_segments cascade';
  end if;
end $$;
create view market.pending_in_segments as
SELECT security_id,
    accession_number,
    report_type,
    filing_date,
    filer_id,
    best_weight,
    round
   FROM ( SELECT f.security_id,
            f.accession_number,
            f.report_type,
            f.filing_date,
            sf.filer_id,
            COALESCE(max(h.weight), 0::numeric) AS best_weight,
            f.segments_parsed_at IS NULL OR COALESCE(f.segments_parser_version::integer, 0) < (( SELECT p.version
                   FROM market.segment_parser p)) AS needs_work,
            row_number() OVER (PARTITION BY f.security_id ORDER BY (COALESCE(( SELECT ff.is_annual
                   FROM market.filing_form ff
                  WHERE ff.source_code = 'nse'::text AND ff.form_code = f.report_type
                 LIMIT 1), false)) DESC, f.filing_date DESC, f.accession_number) AS round
           FROM market.security_filing f
             JOIN market.security_filer sf ON sf.security_id = f.security_id AND sf.source_code = 'nse'::text
             LEFT JOIN market.fund_holding_current h ON h.security_id = f.security_id
          WHERE f.source_code = 'nse'::text AND (EXISTS ( SELECT 1
                   FROM market.filing_form ff
                  WHERE ff.source_code = 'nse'::text AND ff.form_code = f.report_type AND ff.carries_segments))
          GROUP BY f.security_id, f.accession_number, f.report_type, f.filing_date, sf.filer_id, f.segments_parsed_at, f.segments_parser_version) ranked
  WHERE needs_work
  ORDER BY round, best_weight DESC, accession_number;
