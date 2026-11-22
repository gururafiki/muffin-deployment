-- CHINA'S REPORTS HOLDING A FIGURE FUSED INTO A MEMBER NAME ARE READ AGAIN (umbrella docs/deferred/
-- 2026-11-22-some-cninfo-tables-read-the-prior-year-as-revenue.md; the user's decision of
-- 2026-11-22: read them correctly).
--
-- 22 CNINFO reports (20 companies, FY2015 to FY2023) stored a member whose name carries a money
-- figure, `cninfo:其他业务16,327,089.580.36%`. In 16 of them the reader merged this year's amount
-- and share into the name and read last year's amount as the revenue. Each split still
-- reconciled, because the target was last year's total too, and it was stored under this year.
-- Those 16 print this year's `金额` label letter-spaced (`金` and `额` as two items, beside last
-- year's `金额` as one), and the reader matched the label by its exact text. The other 6 had
-- other shapes:
--   - this year's label set 3.3 pt below last year's (舒泰神);
--   - a note after the table read as rows (华大基因, 翰宇药业 twice);
--   - a two-up page whose other half joined the names and ended a table early (上海家化);
--   - a mandated table in 千元 printing whole numbers, which yielded nothing, so the prose
--     after it was read instead (中国中铁 twice).
-- muffin-ingest#196 reads all six shapes. Checked against the reports held on the node: the 22
-- read this year's figures, and none of the other 760 changes.
--
-- One more report goes with them: China Eastern's FY2020, whose change column was read as revenue,
-- so every table summed below zero and a split was placed against a negative total. muffin-ingest
-- #195 stops placing a split against a total of zero or less; a report holding a placed top-level
-- revenue row with no target is exactly that (1 report, measured 2026-11-22).
--
-- So every report whose stored rows hold such a member is put behind the parser: parser version 0,
-- `segments_parsed_at` kept, as the CNINFO re-queues of 2026-11-15 and 11-16 did. Stage 2 retracts
-- the report's rows by accession and writes what the reader now produces. A name with a share but
-- no money figure is real (`钒钛铁精矿（61%）`, a product grade) and is not matched.
--
-- ORDER: the reader rolls first. A re-queue spent while the old reader could still run re-reads
-- each report into the same rows (the 2026-09-07 CNINFO re-walk, recorded in CLAUDE.md).

do $$
declare n int;
begin
  if exists (select 1 from market.one_shot where key = 'cninfo-requeue-fused-figure-2026-11-22') then
    raise notice 'cninfo-requeue-fused-figure: already applied';
    return;
  end if;

  update market.security_filing f
     set segments_parser_version = 0
   where f.source_code = 'cninfo'
     and coalesce(f.segments_parser_version, 0) <> 0  -- read, and not already behind the parser
     and exists (
           select 1 from market.security_segment g
            where g.security_id = f.security_id
              and g.accession_number = f.accession_number
              and g.source_code = 'cninfo'
              and (g.member_code ~ '[0-9]{1,3}(,[0-9]{3})+\.[0-9]{2}'
                   or (g.metric_code = 'revenue' and g.partition_id > 0
                       and g.parent_member is null and g.reconciled_to is null)));
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason) values (
    'cninfo-requeue-fused-figure-2026-11-22',
    format('re-queued %s CNINFO reports holding a member name with a money figure fused into it, '
           'or a split placed against no positive total', n));
  raise notice 'cninfo-requeue-fused-figure: re-queued % rows', n;
end $$;
