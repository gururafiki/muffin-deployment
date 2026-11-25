-- CHINA'S REPORTS WITH A WRONG UNIT LINE, AND ONE DATED AFTER ITS OWN PUBLICATION, ARE READ AGAIN
-- (umbrella docs/deferred/2026-11-23-some-cninfo-tables-state-yuan-over-figures-in-ten-thousands.md;
-- the user's decision of 2026-11-23: check the split against the company's revenue).
--
-- muffin-ingest#200 multiplies a table read in the wrong unit by 10,000 or 1,000 where its placed
-- revenue split, so scaled, lands within 0.3-1.2 of the company's stated revenue for the year.
-- Measured 2026-11-23: 25 CNINFO reports hold a placed revenue split totalling under 10,000,000
-- yuan (航天长峰 FY2025 at 0.12 m for a 1.23 bn line). They are re-queued here. Those whose year has
-- no stated revenue (15 of them, 2015-2021) read back unchanged, which costs one re-read each.
--
-- The same pass re-queues every CNINFO report whose stored period ends AFTER the report was
-- published, which no report can state. One holds 2079-12-31 (filed 2012-03-15). The misdated
-- repair (20261123100000) took only lags of two years or more and so missed it, and it sits at the
-- current parser version, so the drain would not reach it. A re-read under #199's year rule
-- retracts its rows per accession.
--
-- ORDER: muffin-ingest#200 (rolled 2026-11-25 10:47) and #201 roll first, or the re-queue re-reads
-- each report into the same rows. #201 reads `单位（万元）` without a colon and dates a report by the
-- last plausible year in its cover's run, which a stock code no longer captures (0020532010 was
-- 2053). Measured 2026-11-25, after CNINFO pass 7 walked the older search pages: 67 reports hold a
-- split under 10 m yuan (42 of them FY2007-2011) and 11 are dated after their publication.
-- Re-queued means parser version 0, with `segments_parsed_at` kept. A report already behind the
-- parser is left alone and not counted.

do $$
declare
  n_units int;
  n_future int;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-units-and-future-year-2026-11-23') then
    raise notice 'cninfo-units-and-future-year: already applied';
    return;
  end if;

  update market.security_filing f
     set segments_parser_version = 0
   where f.source_code = 'cninfo'
     and coalesce(f.segments_parser_version, 0) <> 0
     and exists (
       select 1
         from market.security_segment g
        where g.security_id = f.security_id
          and g.accession_number = f.accession_number
          and g.source_code = 'cninfo'
          and g.metric_code = 'revenue'
          and g.period_type = 'annual'
          and g.partition_id > 0
          and g.parent_member is null
          and g.reconciled_to < 10000000);
  get diagnostics n_units = row_count;

  update market.security_filing f
     set segments_parser_version = 0
   where f.source_code = 'cninfo'
     and coalesce(f.segments_parser_version, 0) <> 0
     and f.report_date is not null
     and exists (
       select 1
         from market.security_segment g
        where g.security_id = f.security_id
          and g.accession_number = f.accession_number
          and g.source_code = 'cninfo'
          and g.period_ending > f.report_date);
  get diagnostics n_future = row_count;

  insert into market.one_shot (key, reason) values (
    'cninfo-units-and-future-year-2026-11-23',
    format('re-queued %s CNINFO reports with a revenue split under 10 m yuan and %s dated after '
           'their own publication', n_units, n_future));
  raise notice 'cninfo-units-and-future-year: % + % reports re-queued', n_units, n_future;
end $$;
