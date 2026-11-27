CREATE OR REPLACE FUNCTION market.file_edinet_filings(p_edinet_codes text[] DEFAULT NULL::text[])
 RETURNS TABLE(filed integer, withdrawn_filings integer, withdrawn_segments integer)
 LANGUAGE sql
AS $function$
  with wanted as (
    select f.security_id, d.doc_id, d.filed_on, d.period_end, d.xbrl
      from market.edinet_document d
      join market.security_filer f on f.source_code = 'edinet' and f.filer_id = d.edinet_code
     -- An annual report is ordinance 010, form 030000; its amendment (doc type 130) is form 030001.
     where d.ordinance_code = '010' and d.form_code = '030000'
       and not d.withdrawn
       and (p_edinet_codes is null or d.edinet_code = any (p_edinet_codes))
  ),
  filed as (
    insert into market.security_filing as sf
           (security_id, accession_number, filing_date, report_date, report_type, source_code, is_xbrl)
    select w.security_id, w.doc_id, w.filed_on, w.period_end, '有価証券報告書', 'edinet', w.xbrl
      from wanted w
    on conflict (security_id, accession_number) do update
       set filing_date = excluded.filing_date,
           report_date = excluded.report_date,
           report_type = excluded.report_type,
           is_xbrl = excluded.is_xbrl
     where (sf.filing_date, sf.report_date, sf.report_type, sf.is_xbrl)
           is distinct from (excluded.filing_date, excluded.report_date, excluded.report_type,
                             excluded.is_xbrl)
    returning 1
  ),
  gone as (
    select d.doc_id
      from market.edinet_document d
     where d.withdrawn and (p_edinet_codes is null or d.edinet_code = any (p_edinet_codes))
  ),
  gone_segments as (
    delete from market.security_segment g
     using gone
     where g.source_code = 'edinet' and g.accession_number = gone.doc_id
    returning 1
  ),
  gone_filings as (
    delete from market.security_filing sf
     using gone
     where sf.source_code = 'edinet' and sf.accession_number = gone.doc_id
    returning 1
  )
  select (select count(*) from filed)::integer,
         (select count(*) from gone_filings)::integer,
         (select count(*) from gone_segments)::integer
$function$;
