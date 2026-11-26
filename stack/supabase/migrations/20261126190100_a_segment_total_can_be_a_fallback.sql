-- A regulator's segment total concept can be a FALLBACK: consulted only when the vocabulary places no
-- revenue split in a filing (Phase 6c step 2, docs/specs/2026-11-26-more-segment-sources.md).
--
-- WHY. Measured 2026-11-26 over every held SEC annual filing of FY2023+ (2,827 filings of securities
-- that already have a split, 1,529 of securities that do not): adding the bank and utility totals
-- `RevenuesNetOfInterestExpense`, `RevenueAndOperatingIncome` and
-- `RegulatedAndUnregulatedOperatingRevenue` as ORDINARY concepts gave 15 filings of 6 companies
-- their first split (Goldman, Nomura, NextEra, DTE, XP, Community Financial), and also changed 24
-- filings of 13 companies that already had one. A second total the members sum to competes with the
-- first: Equinor's served FY2023 split moved from 155.9 bn to 106.8 bn, NatWest's from 16.6 bn to
-- 13.2 bn, and Enel Chile lost a year. As a fallback, a filing that places a revenue split keeps
-- exactly what it placed (muffin-ingest `segments.segment_facts`).
--
-- The rows come in a later migration, after the ingest roll that reads this column: the code running
-- before it would read them as ordinary concepts.

alter table market.segment_total_concept add column if not exists fallback boolean not null default false;

comment on column market.segment_total_concept.fallback is
  'Consulted only when the global vocabulary plus this regulator''s non-fallback rows place no flat '
  'revenue split in a filing. A total that competes with the one a filing already reconciles to '
  'changes splits that were right (Equinor FY2023: 155.9 bn -> 106.8 bn when merged).';
