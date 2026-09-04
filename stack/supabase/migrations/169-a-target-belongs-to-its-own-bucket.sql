-- RE-PARSE: `reconciled_to` was the WINNING BUCKET's target, stamped on the whole group.
--
-- `segmentFactsFrom` groups candidates by `axis|periodEnding` — so ONE group holds every metric AND
-- both period types that share a reporting date, and a fiscal-year end is also Q4's end (the same
-- collision migration 106 had to put into `security_statement`'s primary key). Which members belong
-- together IS one fact per axis per date and is deliberately shared across that group; the
-- consolidated figure they were reconciled against is NOT — it belongs to one metric over one span.
--
-- MEASURED 2026-09-04 on the live data: 3,021 of 11,211 flat revenue splits did not sum to the
-- target stored beside them, and the damage tracked the shape exactly — 47% of older comparatives
-- wrong against 24% of quarters and 26% of newest annuals, with the largest ratio bucket below 0.5,
-- which is a quarter's split against a year's total. Ruled out first, by measurement: it is not a
-- currency effect (USD 2,831 of 3,059, in proportion to the population), not a scale or units error
-- (14 ratios near a power of ten), and not a target that is one member rather than the total (13).
--
-- The SPLITS themselves were never wrong — only the figure recorded beside them — so nothing served
-- to a reader was incorrect. What it cost was the guard: `check_segments_reconcile` asserts a split
-- against its stored target, so a quarter carrying the year's revenue read as a defect. Every one of
-- those was a false alarm about correct data.
--
-- Bumping the version re-queues every filing through `pending_segments`, which is the mechanism
-- migration 158 records for exactly this. The parse is idempotent and the upsert overwrites, so the
-- corrected target replaces the borrowed one as each filing comes round.
update market.segment_parser set version = version + 1;

comment on column market.security_segment.reconciled_to is
  'The consolidated figure THIS split was accepted against — for its own metric, period type and span. NOT shared across the group: the partition MAP is one fact per (axis, period end) and is applied across metrics and period types deliberately, but the target is not, and stamping the winning bucket''s target on the whole group gave a quarter the year''s revenue for 3,021 of 11,211 splits. Null where the filing never states that metric undimensioned for that span, which is the honest answer — a consumer must skip a null target rather than assert against a borrowed one.';
