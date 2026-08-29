-- KOREA FILES THE SAME XBRL, WITH ONE MORE AXIS — THE SPIKE PASSED.
--
-- The plan gated Japan and Korea on a feasibility spike rather than assuming, because Europe's
-- ESEF had looked like the obvious answer and turned out to carry ZERO segment axes: it mandates
-- detailed tagging of the primary statements only, and block-tags the IFRS 8 note as text.
--
-- KOREA IS NOT THAT. Measured 2026-08-29 against a real DART filing (SK Gas, FY2025), the XBRL
-- package is a full 7.1 MB instance with definition and presentation linkbases, and it carries the
-- IFRS axes this parser ALREADY handles for Diageo:
--
--     ifrs-full:ProductsAndServicesAxis          28
--     ifrs-full:SegmentConsolidationItemsAxis    20
--     ifrs-full:SegmentsAxis                     16
--     ifrs-full:GeographicalAreasAxis             8
--
-- So Korea needs no new parser and no new taxonomy — it needs ONE control-table row, plus three
-- rules the spike forced out (all in `segments.ts`, all mutation-proven).
--
-- ── WHY THAT ROW NEEDS A PINNED MEMBER ────────────────────────────────────────────────────────
--
-- Every Korean fact carries `ifrs-full:ConsolidatedAndSeparateFinancialStatementsAxis`, and it is
-- NOT a harmless qualifier: on that one filing, **1,538 facts are `ConsolidatedMember` and 1,213
-- are `SeparateMember`** — parent-company-only accounts, a different set of numbers for the same
-- company and period. Treating the axis as open would let a parent-only product split be stored
-- beside a consolidated one, or reconciled against it. Treating it as unknown — which is what
-- happened before this row existed — rejects every fact in the country and yields nothing while
-- parsing perfectly.
--
-- Hence `required_member`: a qualifier may pin the member a fact must carry.
alter table market.segment_axis add column if not exists required_member text;

comment on column market.segment_axis.required_member is
  'A member this axis MUST carry for the fact to be kept; NULL means any. `srt:ConsolidationItemsAxis = OperatingSegments` narrows a fact without changing what it measures, so it is open. Korea''s ConsolidatedAndSeparateFinancialStatementsAxis is not: SeparateMember is parent-only accounts, and mixing those with consolidated figures is a different company''s numbers.';

insert into market.segment_axis (taxonomy, axis, kind, priority, required_member) values
  ('ifrs-full', 'ifrs-full:ConsolidatedAndSeparateFinancialStatementsAxis', 'qualifier', 0,
   'ifrs-full:ConsolidatedMember')
on conflict (taxonomy, axis) do update
  set kind = excluded.kind, priority = excluded.priority,
      required_member = excluded.required_member;

-- Also seen on the Korean filing and harmless, but it must be DECLARED or it disqualifies the fact
-- as unknown — the same trap as the axis above, one level quieter.
insert into market.segment_axis (taxonomy, axis, kind, priority, required_member) values
  ('ifrs-full', 'ifrs-full:TimingOfTransferOfGoodsOrServicesAxis', 'qualifier', 0, null),
  ('ifrs-full', 'ifrs-full:MajorCustomersAxis',                   'qualifier', 0, null)
on conflict (taxonomy, axis) do update
  set kind = excluded.kind, priority = excluded.priority,
      required_member = excluded.required_member;

notify pgrst, 'reload schema';
