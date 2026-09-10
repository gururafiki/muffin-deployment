-- AN ELIMINATION COLUMN IS NOT A SEGMENT SPLIT, AND LEAVING THE QUALIFIER OPEN STORED IT AS ONE.
--
-- Found on the FIRST live Korean parse, 2026-09-05, by reading the rows the reconciliation guard
-- flagged rather than the count it reported — it was inside the tripwire, so CI was green.
--
-- HYUNDAI MOBIS, FY2025 `Revenue`, straight from its instance:
--
--   ConsolidatedMember only ............................  61,118,127,000,000   the consolidated figure
--   SegmentConsolidationItemsAxis = OperatingSegments ..  76,544,947,000,000   gross, pre-elimination
--   SegmentConsolidationItemsAxis = Elimination ........ -15,426,820,000,000
--
--   76,544,947 - 15,426,820 = 61,118,127 exactly. The two qualifier groups are the two COLUMNS of
--   the segment table, and with the qualifier open BOTH are admitted as segment facts.
--
-- The parser stored the ELIMINATION column: AutoParts -10,901,986,000,000 and after-sales
-- -4,524,834,000,000, a served split summing to MINUS 15.4 trillion won for a company with 61
-- trillion of revenue. The operating column, which is the real split, sums to 76,544,947,000,000 —
-- exactly the `reconciled_to` already stamped on those rows. Every individual number was correct
-- and correctly attributed; the wrong COLUMN was chosen.
--
-- MIGRATION 155 PREDICTED THE OPPOSITE, IN WRITING: "`srt:ConsolidationItemsAxis = OperatingSegments`
-- narrows a fact without changing what it measures, so it is open." It does change what it measures.
-- That comment is corrected below.
--
-- WHY THIS IS ONE ROW AND NOT A PARSER CHANGE. `required_member` already rejects a fact whose
-- qualifier carries the wrong member, and — this is the part that makes it safe — it only fires
-- when the axis is PRESENT on the fact. A filer that never uses the axis is untouched.
--
-- VERIFIED AGAINST THE FILER IT MUST NOT BREAK. Samsung's four correct segment members all carry
-- `OperatingSegmentsMember`, so they survive; the only facts it additionally drops are two
-- Samsung `Revenue` figures carrying `SegmentsAxis` with NO qualifier, which were never part of the
-- served split.
--
-- DELIBERATELY NOT APPLIED TO THE us-gaap CONSOLIDATION AXES. Measured the same hour: 200+ served
-- rows carry a negative revenue under `sec-segments`, and the ones sampled are LEGITIMATE — Visa's
-- `v:ClientIncentivesMember` and Coca-Cola's `ko:EliminationsMember` are negative lines that make
-- those splits reconcile. Pinning `OperatingSegmentsMember` there would delete the line that makes
-- the arithmetic work. A negative value is not the defect; a split that does not reconcile is, and
-- `check_segments_reconcile` already reports those.

\set ON_ERROR_STOP on

update market.segment_axis
   set required_member = 'ifrs-full:OperatingSegmentsMember'
 where axis = 'ifrs-full:SegmentConsolidationItemsAxis';

comment on column market.segment_axis.required_member is
  'A member this axis MUST carry for the fact to be kept; NULL means any. Rejects only when the axis is PRESENT with a different member, so a filer that omits it is unaffected. Korea''s ConsolidatedAndSeparateFinancialStatementsAxis pins ConsolidatedMember (SeparateMember is parent-only accounts — a different company''s numbers), and SegmentConsolidationItemsAxis pins OperatingSegmentsMember: migration 155 assumed that axis "narrows a fact without changing what it measures", and it does not — the elimination member is the other COLUMN of the segment table, and admitting it stored Hyundai Mobis''s intersegment eliminations as its business-line split.';

-- ── the repair ───────────────────────────────────────────────────────────────────────────────────
--
-- A ONE-SHOT, because this is a DATA REPAIR and migrations re-run on every deploy. Clearing
-- `segments_parsed_at` unconditionally would re-parse every Korean filing for ever, spending the
-- 73.9-second-per-filing budget on work already done.
--
-- The delete is required as well as the re-queue: an upsert cannot retract, so re-parsing writes
-- the OperatingSegments members and leaves the elimination rows sitting beside them — which would
-- be worse than the original defect, since the axis would then carry both columns at once and
-- double-count. Scoped to `dart` because only the IFRS axis changed.
do $$
declare n_rows int; n_filings int;
begin
  if exists (select 1 from market.one_shot where key = 'drop-dart-elimination-splits') then
    raise notice '  --  dart elimination splits already repaired, skipping';
    return;
  end if;

  delete from market.security_segment where source_code = 'dart';
  get diagnostics n_rows = row_count;

  update market.security_filing
     set segments_parsed_at = null, segments_parser_version = null
   where source_code = 'dart' and segments_parsed_at is not null;
  get diagnostics n_filings = row_count;

  insert into market.one_shot (key) values ('drop-dart-elimination-splits');
  raise notice '  --  dropped % dart segment rows, re-queued % filings', n_rows, n_filings;
end $$;

notify pgrst, 'reload schema';
