-- CHINA'S REPORTS READ WITH NO TABLE ARE READ AGAIN, NOW THAT SHENZHEN'S TABLE IS READ (Phase 6
-- step 4, decided by the user 2026-11-16).
--
-- The Dagster reader read China's mandated tables only (`主营业务分行业/分产品/分地区情况`), which
-- Shanghai prints. Shenzhen prints none: its split is one table, `营业收入构成`, with the company's
-- total first and a row per group (分行业, 分产品, 分地区) over its members. Measured in the drain's
-- first runs on 2026-11-16, rows came from 0 of 562 Shenzhen reports against 61 of 163 Shanghai
-- ones, and Shenzhen holds 1,105 of the 2,173 CNINFO filers. muffin-ingest#183 reads that table
-- wherever a report prints no mandated heading; what it read from every Shenzhen report fetched,
-- checked against each PDF, is in the umbrella's docs/specs/2026-11-09-segments-and-regulators.md
-- (step 4, "Shenzhen").
--
-- So the reports already marked read WITHOUT A ROW are read again: 757 measured on 2026-11-16,
-- full PDF reports at the current parser version owning no segment row. A report read with rows
-- was read from its mandated tables, which read exactly as before, and is left alone. As the
-- re-queue of 2026-11-15 did, the marks go to parser version 0 ("behind the parser") rather than
-- null: `segments_parsed_at` stays, so `every_cninfo_report_was_read` reports a re-read in
-- progress. The reports' PDFs are held in raw (fetched the same day), so the re-read asks CNINFO
-- for nothing.
--
-- ORDER: the reader rolls first. A re-queue applied while the old reader could still run would be
-- spent on reads that cannot find the table (the 2026-09-07 CNINFO re-walk, recorded in CLAUDE.md).

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-requeue-no-table-2026-11-16') then
    raise notice 'cninfo-requeue-no-table: already applied';
    return;
  end if;

  update market.security_filing f
     set segments_parser_version = 0
   where f.source_code = 'cninfo'
     and f.report_type = '年度报告'
     and lower(f.accession_number) like '%.pdf'
     and coalesce(f.segments_parser_version, 0) <> 0  -- read, and not already behind the parser
     and not exists (
           select 1 from market.security_segment g
            where g.security_id = f.security_id and g.accession_number = f.accession_number);
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'cninfo-requeue-no-table-2026-11-16',
    format('re-queued %s CNINFO full reports read with no table, for the composition reader', n));
  raise notice 'cninfo-requeue-no-table: re-queued % rows', n;
end $$;
