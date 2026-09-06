-- ONE GRID IS TWO SPLITS, AND ONLY ONE DIRECTION WAS BEING SUMMED.
--
-- Migration 181 taught the parser that a cross-tab is also a flat split when summed ACROSS its
-- parent axis, which recovered Chevron's business lines (Upstream 88,379 + Downstream 142,410 +
-- the filed AllOther 581 = 231,370, the filing's own total). Summing the same grid BY PARENT is
-- equally available and was not computed, so Chevron's own geography rows still read null:
--
--   srt:StatementGeographicalAxis  country:US            revenue: null
--   srt:StatementGeographicalAxis  us-gaap:NonUsMember   revenue: null
--
-- while the four cells that add up to them sat right there — US x Upstream 45,518, US x Downstream
-- 72,485, non-US x Upstream 42,861, non-US x Downstream 69,925. US revenue 118,003 and non-US
-- 112,786 were derivable by addition and shown nowhere. Measured on production before this change:
-- 1,643 parent rollups across 58 securities had no flat fact of their own, 965 of them revenue.
--
-- NO NEW SAFETY RULE. Both directions go through the SAME three guards, and each is what makes
-- this arithmetic rather than invention:
--   * a member the filer states FLATLY is never replaced by our sum — which is also what stops
--     Alphabet's `GoogleServicesMember` being re-synthesised from its own product cells;
--   * the marginal is offered to the ORDINARY partition search and survives only if it reconciles;
--   * a marginal earning NO partition is dropped rather than stored at 0.
-- A filer stating flat {A, B} plus a cross-tab under an unstated parent C gets a synthesised C; if
-- the real split is {A, B}, adding C breaks reconciliation, the search picks {A, B}, and C is
-- dropped.
--
-- PARTIAL COVER IS SERVED, DELIBERATELY. Chevron's geography marginal is 230,789 against a filed
-- 231,370 — 0.25% short, because the 581m `AllOther` segment has no geography — which is inside the
-- 0.5% tolerance. `share-basis.ts` then takes shares against the disclosed sum, so they total 100
-- and the caption names the basis. Requiring exact cover would reject the headline case and every
-- filer with an unallocated segment.
--
-- Verified against the real instances before shipping: Chevron goes from 6 reconciling splits to 8
-- (gaining geography revenue AND cost of revenue) while keeping its business split at 231,370;
-- Novo Nordisk is unchanged, still refusing its 4.2x flat sum and serving the disjoint level on
-- both axes at 309,064; Equinor and Hershey are untouched.

\set ON_ERROR_STOP on

-- GUARDED, for the reason migration 169 was not: an unconditional bump re-queues every filing on
-- EVERY deploy, which is how 94% of the served data came to be stale.
do $$ begin
  if not exists (select 1 from market.one_shot where key = 'segment-parser-parent-marginals') then
    update market.segment_parser set version = version + 1;
    insert into market.one_shot (key) values ('segment-parser-parent-marginals');
  end if;
end $$;

notify pgrst, 'reload schema';
