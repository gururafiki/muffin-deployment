-- A SPLIT THAT EXCEEDS CONSOLIDATED REVENUE IS NOT NECESSARILY DOUBLE-COUNTED.
--
-- Segment revenue INCLUDES intersegment sales; consolidation removes them. So a correct split can
-- legitimately exceed the company's own consolidated figure by exactly the elimination, and this
-- pipeline treats an over-count as a defect — the one direction it refuses to draw.
--
-- SOUTHERN COPPER, FY2018, measured from its own instance. The filing states:
--
--   consolidated revenue (undimensioned)                              7,096,700,000
--   segments: MexicanOpenPit 4,075.9 + Peruvian 2,572.2 + IMMSA 527.9 7,176,000,000
--   us-gaap:IntersegmentEliminationMember                                -79,300,000
--
-- 7,176.0 - 79.3 = 7,096.7 exactly: the filing reconciles perfectly and every number is right. The
-- parser stored `reconciled_to = 7,096,700,000` and the split then read as a 1.01x over-count.
--
-- TWO REASONS THE EXISTING DERIVATION COULD NOT REACH IT, and each had to be fixed:
--
--   Its segment facts carry NO qualifier axis — the filer tags the plain
--   `StatementBusinessSegmentsAxis` facts alongside the qualified ones — so a derivation keyed on
--   the candidates' OWN qualifier member never ran at all.
--
--   The same -79,300,000 is tagged under BOTH `us-gaap:IntersegmentEliminationMember` and
--   `scco:CorporateAndEliminationsMember`: one line, stated once in the segment table and once in
--   the geography table. Summing every member of the axis double-counts it and derives
--   7,255,300,000, which matches nothing — so only a DISTINCT-VALUE sum finds the answer.
--
-- The parser now walks every qualifier axis holding totals for the metric and period and OFFERS
-- both sums as candidates. Offering rather than choosing is what keeps it honest: a candidate is
-- accepted only if the members' own sum already matches it, so it can never select a wrong target,
-- only rescue a split that would otherwise fall back to one. Neither figure is fitted to the
-- answer; both are arithmetic over totals the filing itself states.
--
-- THE FALLBACK IS DELIBERATELY UNCHANGED. A split that reconciles to nothing keeps exactly the
-- target it had before, or widening the search would quietly move every split it fails to rescue.

\set ON_ERROR_STOP on

-- GUARDED, for the reason migration 169 was not: an unconditional bump re-queues all ~213,500
-- filings on EVERY deploy. Southern Copper's filing had already been read at the CURRENT parser
-- version, so without a bump this fix would never reach the filings it corrects.
do $$ begin
  if not exists (select 1 from market.one_shot where key = 'segment-parser-derived-column-totals') then
    update market.segment_parser set version = version + 1;
    insert into market.one_shot (key) values ('segment-parser-derived-column-totals');
  end if;
end $$;

notify pgrst, 'reload schema';
