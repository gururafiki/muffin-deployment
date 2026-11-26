-- CHINA'S OLDER TABLES ARE READ AGAIN, with their own unit and their own end (one-shot).
--
-- muffin-ingest#203 fixes the CNINFO reader's older forms (FY2007-2014), which #199 added and
-- the history walk (pass 7-8) applied to ~11,800 reports:
--   - a table ends at the next numbered section (`2、`, `⑶`) and at a row of indicators set in
--     the name column (`利润总额（元）`), so the balance sheet and the accounting data after a
--     table are no longer read as its members;
--   - `构成情况` headings and a revenue label set glyph by glyph (`营` / `业收入`) are read;
--   - a unit in the column header (`营业收入（万元）`) scales the table, and a `单位：` line drawn
--     as several items is read as one line.
-- Gated 2026-11-26 over 854 held reports against the running reader: the 300 current-form reports
-- unchanged; member names carrying a figure 231 -> 18 (all 18 also in the old read); reconciling
-- splits 123 -> 154 among the changed reports; none stopped reconciling; 20 tables rescaled by
-- exactly 10,000.
--
-- MEASURED 2026-11-26, after pass 8: 142 CNINFO reports hold a placed annual revenue split under
-- 10 m yuan (67 on 11-25), every one read by pass 8, 122 of them FY2012 or earlier with no stored
-- revenue for #200's check to scale against. And 45 reports serve a split holding a statement line
-- item as a member (`货币资金`, `应收票据期末余额为…`).
--
-- THE RE-QUEUE, at the current parser version only (a report already behind it is not counted):
--   older   every full report published before 2016 holding a revenue row: the older forms'
--           output, which the fix can change;
--   tiny    every report holding a placed top-level annual revenue split under 10 m yuan;
--   fused   every report holding a revenue member whose name carries a figure.
-- NOT re-queued: reports read into no rows. The gate gained 2 of 150 of those, and ~10,100 of
-- them would cost ~30 GB of PDF fetches; that is the user's call (umbrella todos.md).
--
-- ORDER: the reader rolls first, or every re-queued report is read back into the same rows.

do $$
declare
  n_older int;
  n_tiny int;
  n_fused int;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-older-tables-2026-11-26') then
    raise notice 'cninfo-older-tables: already applied';
    return;
  end if;

  update market.security_filing f
     set segments_parser_version = 0
   where f.source_code = 'cninfo'
     and f.report_type = '年度报告'
     and f.report_date < date '2016-01-01'
     and coalesce(f.segments_parser_version, 0) <> 0
     and exists (
       select 1
         from market.security_segment g
        where g.security_id = f.security_id
          and g.accession_number = f.accession_number
          and g.source_code = 'cninfo'
          and g.metric_code = 'revenue');
  get diagnostics n_older = row_count;

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
  get diagnostics n_tiny = row_count;

  -- A figure inside a name: digits grouped by commas or with decimals (`12,493.19`, `0.84`), not a
  -- year or a model number standing alone (`2010年`, `A380`).
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
          and g.member_code ~ '\d,\d{3}|\d\.\d{2}');
  get diagnostics n_fused = row_count;

  insert into market.one_shot (key, reason) values (
    'cninfo-older-tables-2026-11-26',
    format('re-queued %s older CNINFO reports with a revenue row, %s with a split under 10 m yuan '
           'and %s with a figure in a member name', n_older, n_tiny, n_fused));
  raise notice 'cninfo-older-tables: % + % + % reports re-queued', n_older, n_tiny, n_fused;
end $$;
