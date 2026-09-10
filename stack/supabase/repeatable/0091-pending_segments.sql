do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_segments';
  if k = 'm' then execute 'drop materialized view if exists market.pending_segments cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_segments cascade';
  end if;
end $$;
create view market.pending_segments as
SELECT security_id,
    accession_number,
    report_type,
    filing_date,
    filing_detail_url,
    cik,
    best_weight,
    round,
    already_read
   FROM ( SELECT f.security_id,
            f.accession_number,
            f.report_type,
            f.filing_date,
            f.filing_detail_url,
            s.cik,
            f.segments_parsed_at IS NOT NULL AS already_read,
            f.segments_parsed_at IS NULL OR COALESCE(f.segments_parser_version::integer, 0) < (( SELECT p.version
                   FROM market.segment_parser p)) AS needs_work,
            COALESCE(max(h.weight), 0::numeric) AS best_weight,
            row_number() OVER (PARTITION BY f.security_id ORDER BY (COALESCE(( SELECT ff.is_annual
                   FROM market.filing_form ff
                  WHERE ff.source_code = 'sec'::text AND ff.form_code = f.report_type
                 LIMIT 1), false)) DESC, f.filing_date DESC, f.accession_number) AS round
           FROM market.security_filing f
             JOIN market.security s ON s.security_id = f.security_id
             LEFT JOIN market.fund_holding_current h ON h.security_id = f.security_id
          WHERE s.cik IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM market.filing_form ff
                  WHERE ff.source_code = 'sec'::text AND ff.form_code = f.report_type AND ff.carries_segments)) AND (EXISTS ( SELECT 1
                   FROM market.security_disclosure sd
                  WHERE sd.security_id = f.security_id AND sd.capability = 'held'::text))
          GROUP BY f.security_id, f.accession_number, f.report_type, f.filing_date, f.filing_detail_url, s.cik, f.segments_parsed_at, f.segments_parser_version) ranked
  WHERE needs_work
  ORDER BY round, already_read DESC, best_weight DESC, accession_number;
