-- A FILING READ UNDER TOO SMALL A BOUND IS RECORDED AS DISCLOSING NOTHING, PERMANENTLY.
--
-- `segmentFactsFromPdf` scanned the first 45 pages for the mandated
-- `主营业务分行业情况` heading. That was measured on two documents, which put it on page 13 and 23
-- — and Canadian Solar's 327-page FY2025 report puts it on page **68**. The resource fetched it,
-- found nothing, and stamped `segments_parsed_at`, which is permanent by design: a filed document
-- is immutable, so "this one discloses no segments" is a fact that never needs revisiting.
--
-- Except it was not a fact about the document. It was a fact about our bound.
--
-- The bound is now 90, measured per document in isolation (Canadian Solar 298 ms / 124 MB, LONGi
-- 248 ms / 140 MB against a 90 s / 256 MB worker). This clears the stamp on the filings read under
-- the old one so they are offered again.
--
-- NARROW ON PURPOSE, AND NOT A PARSER VERSION BUMP. A bump re-queues every filing of every source
-- — 204,000 of them — to correct a bound that only ever affected CNINFO. This clears only cninfo
-- filings that produced NO segment rows: a filing that yielded a split was found, so its stamp is
-- honest whatever the bound was.
--
-- A ONE-SHOT, because migrations re-run on every deploy and this is a data repair. Clearing these
-- stamps every deploy would re-read the whole Chinese corpus for ever.
do $$
declare v_cleared integer;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-scan-bound-90') then
    return;
  end if;

  update market.security_filing f
     set segments_parsed_at = null,
         segments_parser_version = null
   where f.source_code = 'cninfo'
     and f.segments_parsed_at is not null
     and not exists (
       select 1 from market.security_segment g
        where g.security_id = f.security_id
          and g.accession_number = f.accession_number
     );
  get diagnostics v_cleared = row_count;
  raise notice 'cninfo: re-queued % filings read under the 45-page scan bound', v_cleared;

  insert into market.one_shot (key) values ('cninfo-scan-bound-90');
end $$;

notify pgrst, 'reload schema';
