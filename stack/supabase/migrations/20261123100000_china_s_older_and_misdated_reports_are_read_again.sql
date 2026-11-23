-- CHINA'S OLDER REPORTS AND ITS MISDATED ONES ARE READ AGAIN (umbrella docs/deferred/
-- 2026-11-15-cninfo-reads-only-the-newest-search-page.md and 2026-11-23-cninfo-reports-filed-
-- under-the-wrong-year.md; the user's decision of 2026-11-23: build the older readers).
--
-- muffin-ingest#199 reads the FY2007-2014 table forms, only where the current forms give nothing.
-- Over 55 reports from CNINFO's second search page, 0 read before. It also reads some current
-- reports the current reader missed, so every full report read into no rows is read again, as on
-- 2026-11-22.
--
-- THE SAME CHANGE FIXES THE YEAR A REPORT IS FILED UNDER. The reader dates a report by the year
-- before `年度报告` on its cover. It missed covers that letter-space the title (`2010 年 年 度 报
-- 告`) or write the year in Chinese numerals (`二零二五年年度报告`), and took a later mention of
-- last year's report instead. Measured 2026-11-23: 234 CNINFO reports are stored two or more
-- years before their filing year (143 by two years, 51 by three, the rest by four to 22), across
-- ~200 securities. 紫光股份's FY2025 report was filed as FY2024.
--
-- The segment key leaves out the accession, so each misdated report OVERWROTE its company's real
-- rows for that year. Re-reading is not enough on its own. The shared writer never overwrites a
-- key that a NEWER filing holds (`segment_tables._held_by_newer`), so the real report for that
-- year, read first, would find its keys held and be marked read with its rows still missing. So:
--   1. the misdated reports' rows are deleted. That is what their own re-read would retract,
--      per accession, and it makes the order of the drain irrelevant;
--   2. those reports, and every other full report of the same securities, are re-queued, so the
--      years they overwrote are written again. A report filed honestly late reads back into the
--      same rows;
--   3. every full report read into no rows is re-queued.
-- Re-queued means parser version 0, with `segments_parsed_at` kept, as every CNINFO re-queue
-- since 2026-11-15 did. A report already behind the parser is left alone and not counted.
--
-- ORDER: the reader rolls first. A re-queue spent while the old reader could still run re-reads
-- each report into the same rows (the 2026-09-07 CNINFO re-walk, recorded in CLAUDE.md).

do $$
declare
  n_rows int;
  n_misdated int;
  n_siblings int;
  n_norows int;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-older-and-misdated-2026-11-23') then
    raise notice 'cninfo-older-and-misdated: already applied';
    return;
  end if;

  drop table if exists pg_temp.misdated;
  create temporary table misdated on commit drop as
  select distinct g.security_id, g.accession_number
    from market.security_segment g
    join market.security_filing f
      on f.security_id = g.security_id and f.accession_number = g.accession_number
   where g.source_code = 'cninfo'
     and g.period_type = 'annual'
     and f.report_date is not null
     and extract(year from f.report_date) - extract(year from g.period_ending) >= 2;

  delete from market.security_segment g
   using misdated m
   where g.security_id = m.security_id
     and g.accession_number = m.accession_number
     and g.source_code = 'cninfo';
  get diagnostics n_rows = row_count;

  update market.security_filing f
     set segments_parser_version = 0
    from misdated m
   where f.security_id = m.security_id
     and f.accession_number = m.accession_number
     and f.source_code = 'cninfo'
     and coalesce(f.segments_parser_version, 0) <> 0;
  get diagnostics n_misdated = row_count;

  update market.security_filing f
     set segments_parser_version = 0
   where f.source_code = 'cninfo'
     and f.report_type = '年度报告'
     and coalesce(f.segments_parser_version, 0) <> 0
     and f.security_id in (select security_id from misdated);
  get diagnostics n_siblings = row_count;

  update market.security_filing f
     set segments_parser_version = 0
   where f.source_code = 'cninfo'
     and f.report_type = '年度报告'
     and coalesce(f.segments_parser_version, 0) <> 0
     and not exists (select 1 from market.security_segment g
                      where g.security_id = f.security_id
                        and g.accession_number = f.accession_number);
  get diagnostics n_norows = row_count;

  insert into market.one_shot (key, reason) values (
    'cninfo-older-and-misdated-2026-11-23',
    format('deleted %s rows of misdated CNINFO reports; re-queued %s misdated reports, %s other '
           'full reports of their securities and %s full reports read into no rows',
           n_rows, n_misdated, n_siblings, n_norows));
  raise notice 'cninfo-older-and-misdated: % rows deleted, % + % + % reports re-queued',
    n_rows, n_misdated, n_siblings, n_norows;
end $$;
