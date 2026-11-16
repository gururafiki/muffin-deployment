-- THE CHINA SEGMENT READER LEAVES THE EDGE (Phase 6 step 4, decided by the user 2026-11-09 and
-- 2026-11-15).
--
-- muffin-ingest's `cninfo_segments` job (`raw_cninfo_filings` -> `cninfo_segment`) now searches each
-- CNINFO filer's annual reports, files them in `market.security_filing` and reads each full report's
-- mandated tables into `market.security_segment` under the same `cninfo` source. Decision 3 is that
-- two writers never run at once, so both edge resources retire before the Dagster schedules start.
--
-- RETIRES: security-cn-segments
-- RETIRES: cn-filings
--
-- NOT A LINE-FOR-LINE PORT (the user, 2026-11-15). Golden parity over 716 reports (2026-11-16)
-- found 355 of the 516 reports the edge read carrying at least one defect: a 万元 table stored as
-- yuan, ten thousand times too small (73 reports); total rows (合计, 小计) stored beside their parts
-- (118); the sales-model table read into the last table (131); a money cell set on two lines kept
-- as its last line, so 储能行业 was 194.20 yuan for 2,660,336,194.20 (fragments in 47, names glued
-- or cut in 119); a margin read as money (20). The edge also read one page, while 256 of 537 table
-- pages run onto the next. The Dagster reader fixes each: tables found went 1,189 -> 1,467 and
-- reconciling ones 1,070 -> 1,409, with every difference from the edge classified in
-- docs/specs/2026-11-09-segments-and-regulators.md (umbrella), step 4.
--
-- SO EVERY REPORT THE EDGE READ IS READ AGAIN, and all China segments come from one reader. The
-- marks below go to parser version 0, "behind the parser" rather than "never read", as the SEC
-- re-queue of 2026-11-14 did: `segments_parsed_at` stays, so `every_cninfo_report_was_read` reports a
-- re-read in progress (WARN), and the lane's own retraction replaces each report's rows by
-- accession when it reads it. Only full PDF reports: the edge also marked 18 summaries and one
-- English edition read, which the Dagster lane never reads, and 7,509 `.js` and `.html`
-- announcements were filed as reports and never read by either.
--
-- The names are in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate. The handlers,
-- `cn.ts`, `cn-pdf.ts` and the `pending_cn_*` views stay until step 8 deletes them after three clean
-- days, so rolling back is re-enabling one rotation row, re-scheduling one job and removing two map
-- entries.

update market.cron_resource set enabled = false where resource = 'security-cn-segments';

do $$
begin
  -- Guarded on the table, not with an exception handler: the migration tests run on plain
  -- Postgres with no pg_cron, where even planning a query that names `cron.job` fails.
  if to_regclass('cron.job') is not null then
    execute $q$select cron.unschedule(jobname) from cron.job where jobname = 'muffin-cn-filings'$q$;
  end if;
end $$;

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-requeue-edge-reads-2026-11-15') then
    raise notice 'cninfo-requeue-edge-reads: already applied';
    return;
  end if;

  update market.security_filing f
     set segments_parser_version = 0
   where f.source_code = 'cninfo'
     and f.report_type = '年度报告'
     and lower(f.accession_number) like '%.pdf'
     and f.segments_parsed_at is not null;
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'cninfo-requeue-edge-reads-2026-11-15',
    format('re-queued %s CNINFO full reports the edge read, for the Dagster reader', n));
  raise notice 'cninfo-requeue-edge-reads: re-queued % rows', n;
end $$;
