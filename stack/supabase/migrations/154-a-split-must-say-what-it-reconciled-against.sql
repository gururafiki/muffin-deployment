-- A SPLIT MUST SAY WHAT IT RECONCILED AGAINST, OR A GUARD CANNOT TELL A DOUBLE COUNT FROM A
-- DISAGREEMENT BETWEEN SOURCES.
--
-- `check_segments_reconcile.py` compared a stored split against `security_metric`, which is a
-- SECOND, INDEPENDENTLY DERIVED total: companyfacts merges every filing a company has made and
-- resolves a revenue concept across all of them, while the parser reads ONE document and resolves
-- within it. When the two disagree the split looks broken and is not — the members still add up to
-- exactly what they were accepted against.
--
-- Measured on production after the first day of ingestion: of 380 splits, five "failed" and every
-- one was this. A quarterly split of 3,186,000,000 was compared against a companyfacts figure of
-- 2,165,000,000 (ratio 1.47) though its two members — Product and Service — are the whole company
-- by construction.
--
-- With the target stored, the assertion becomes exact and needs no second source: does this split
-- still sum to the number it was accepted against? That question has one right answer and cannot
-- be confused by a provider's vocabulary. Drift against companyfacts remains worth reporting, but
-- it is a SOURCE-AGREEMENT observation rather than a defect in the split.
-- THE COLUMN ITSELF IS DECLARED IN MIGRATION 141, not here, and that is not tidiness. Migration
-- 150's `security_segment_latest` lists its columns explicitly and runs BEFORE this file, so a
-- column introduced at 154 cannot appear in that view without 150 failing on the first pass —
-- and a view that omits a column answers **400**, not null, to every reader asking for it. The
-- guard this column exists for could not run at all until the declaration moved.
--
-- What remains here is the part that must happen exactly once: re-reading what is already stored.

-- ── AND EVERY FILING ALREADY READ MUST BE READ AGAIN ─────────────────────────────────────────
--
-- The rows written before this column existed carry NULL, and their filings are stamped
-- `segments_parsed_at`, so nothing would ever revisit them — the new guard would find nothing to
-- check and fail as vacuous, which is correct behaviour reporting a real gap.
--
-- This is precisely what `segment_parser.version` was built for in migration 141: bumping it
-- re-queues every filing, with no deploy of its own and no hand-written UPDATE. Using it here is
-- the first time the mechanism has been needed, and it is why the backlog was designed around a
-- version rather than a plain "has it been parsed" flag.
--
-- Guarded by `market.one_shot` so a re-parse happens ONCE rather than on every deploy: migrations
-- re-run in full, and an unconditional bump would re-queue all 30,000 filings every time anyone
-- deployed anything.
do $$ begin
  if not exists (select 1 from market.one_shot where key = 'segment-parser-v2-reconciled-to') then
    update market.segment_parser set version = version + 1;
    insert into market.one_shot (key) values ('segment-parser-v2-reconciled-to');
  end if;
end $$;

notify pgrst, 'reload schema';
