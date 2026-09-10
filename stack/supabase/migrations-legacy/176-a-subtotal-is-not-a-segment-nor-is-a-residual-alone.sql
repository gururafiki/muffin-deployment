-- A SUBTOTAL IS NOT A SEGMENT, AND A RESIDUAL ON ITS OWN IS NOT A SPLIT.
--
-- Two roles a member can play that disqualify it from *being* a business line, measured on
-- Chevron's own FY2025 instance and then across the whole served table. They need opposite
-- treatment, which is why one table classifies rather than two tables listing.
--
-- ── subtotal: DROP IT ───────────────────────────────────────────────────────────────────────────
-- On `StatementBusinessSegmentsAxis` with the operating-segments qualifier Chevron publishes
-- exactly two facts:
--
--   ReportableSegmentAggregationBeforeOtherOperatingSegmentMember   230,789,000,000
--   AllOtherSegmentsMember                                               581,000,000
--                                                                  ----------------
--   qualifier total                                                 231,370,000,000
--
-- They reconcile perfectly, so the parser accepted them as a split. The first is a SUBTOTAL by
-- definition ("aggregation before other operating segments"), so a partition containing it
-- double-counts by construction. Chevron's real segments exist only as a business x geography
-- CROSS-TAB, which is why the flat axis carries nothing else.
--
-- ── residual: KEEP IT, BUT IT CANNOT STAND ALONE ────────────────────────────────────────────────
-- Dropping the subtotal was predicted to leave one member at 581m that reconciles to nothing, so
-- that nothing would be served. MEASURED, THAT PREDICTION WAS WRONG and the served row survived
-- unchanged: `bestMap` — which members belong together — is learned from the bucket that places
-- the most members and applied to every metric on the axis, so revenue inherited partition 1 from
-- `depreciation` (AllOther 283m + Upstream 18,445m + Downstream 1,404m = 20,132m, which reconciles
-- exactly) and served `AllOtherSegments 581m` against a target of 231,370,000,000 — 0.25% of the
-- company, presented as its business breakdown.
--
-- The two obvious repairs are both wrong, and the same filing disproves each. Requiring the
-- inherited partition to be COMPLETE in its bucket would discard Chevron's `total_assets`, where
-- Upstream + Downstream = 312,218m reconciles exactly WITHOUT the residual. Requiring it to
-- RECONCILE in its own bucket would reject segment profit everywhere — ASC 280 and IFRS 8 mandate
-- a reconciliation rather than an identity, so unallocated cost means profit never sums, and that
-- is the number this feature exists to serve.
--
-- What is actually wrong is narrower: every member left in the bucket is a RESIDUAL — the
-- remainder after the named segments — so the split describes the leftovers and nothing else.
-- Measured across the served table: 45 splits are residual-only, median 2.82% of their own target
-- and 27 of them under 10%, against 23,802 splits holding at least one real member, which this
-- rule does not touch. The residual is still kept wherever it sits beside a real segment; it is
-- only barred from constituting a split by itself.
--
-- SEEDED FROM THE DATA, NOT FROM MEMORY. Exactly three codes account for all 45. Four further
-- members that would have been plausible to list (CorporateNonSegment, MaterialReconcilingItems,
-- SegmentReconcilingItems, OtherSegments) account for ZERO and are deliberately not seeded — a new
-- one is a row, which is the point of a control table.
--
-- It is deliberately NOT `segment_member`, whose `kind` is constrained to product/business/
-- geography — neither role is any of those, and widening that check would let a subtotal be served
-- as a business line by any caller that forgot.

\set ON_ERROR_STOP on

drop table if exists market.segment_excluded_member;

create table if not exists market.segment_member_class (
  member_code text primary key,
  class       text not null check (class in ('subtotal', 'residual')),
  reason      text not null,
  as_of       timestamptz not null default now()
);

comment on table market.segment_member_class is
  'Members that cannot be a business line, and why. `subtotal` is dropped before partitioning — a split containing one double-counts by construction. `residual` is KEPT (it is a real part of a split that includes named segments) but may never be the whole of one, or the leftovers get served as the company. Adding a row needs no deploy; a `segment_parser.version` bump re-reads every filing.';

insert into market.segment_member_class (member_code, class, reason) values
  -- SINGULAR `Segment`, verified against Chevron's instance. The plural reads more naturally and
  -- is what I seeded first; it matches nothing, and the exclusion silently did nothing at all.
  ('us-gaap:ReportableSegmentAggregationBeforeOtherOperatingSegmentMember', 'subtotal',
   'The sum of the reportable segments — Chevron FY2025 publishes it beside AllOther and the two reconcile exactly (230,789m + 581m = 231,370m), which made a subtotal plus a residual look like a business-line split.'),
  ('ifrs-full:ReportableSegmentsMember', 'subtotal',
   'IFRS 8 aggregate of the reportable segments; same shape as the us-gaap member above.'),
  ('us-gaap:OperatingSegmentsMember', 'subtotal',
   'The aggregate of the operating segments. It is a QUALIFIER member on the consolidation-items axis, but some filers also tag it on the segment axis itself, where it is the total rather than a segment.'),
  ('us-gaap:AllOtherSegmentsMember', 'residual',
   'Everything not separately reportable. 27 served splits consist of it alone, ratios from 0.000 to 1.000 of their own target — and a split that is 100% "all other" is no more a breakdown than one that is 0.25%.'),
  ('us-gaap:CorporateAndOtherMember', 'residual',
   'The corporate leftovers bucket. 16 served splits consist of it alone, up to 62.6% of the target — large, and still not a business line.'),
  ('ifrs-full:AllOtherSegmentsMember', 'residual',
   'IFRS counterpart; 2 served splits consist of it alone, at 1.7% and 1.8% of target.')
on conflict (member_code) do update set class = excluded.class, reason = excluded.reason;

grant select on market.segment_member_class to anon, authenticated, service_role;
grant insert, update, delete on market.segment_member_class to service_role;
alter table market.segment_member_class enable row level security;
drop policy if exists segment_member_class_read on market.segment_member_class;
create policy segment_member_class_read on market.segment_member_class for select using (true);

-- ── the re-parse ────────────────────────────────────────────────────────────────────────────────
-- GUARDED, for the reason migration 169 was not: an unconditional bump re-queues all 213,500
-- filings on EVERY deploy, which is how 94% of the served data came to be stale.
do $$ begin
  if not exists (select 1 from market.one_shot where key = 'segment-parser-member-roles') then
    update market.segment_parser set version = version + 1;
    insert into market.one_shot (key) values ('segment-parser-member-roles');
  end if;
end $$;

notify pgrst, 'reload schema';
