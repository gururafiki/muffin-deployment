-- A CROSS-TAB IS ALSO A FLAT SPLIT, SUMMED THE OTHER WAY.
--
-- A cross-tab cell reconciles to its PARENT's value, so a filer who publishes the grid without
-- stating the parent's own total leaves every cell unplaceable. CHEVRON FY2025 does exactly that:
--
--   US      x Upstream 45,518   x Downstream 72,485
--   non-US  x Upstream 42,861   x Downstream 69,925
--
-- and no flat regional revenue anywhere in the filing. All four cells sat at partition 0, so a
-- complete, exactly-reconciling business-line split was in the database and on no page. Measured
-- 2026-09-05: 19,990 such cells across 153 securities, 93 of them with nothing served on that axis.
--
-- Summed across the parent axis the grid recovers the split the filer did publish, just not flatly
-- — Upstream 88,379 and Downstream 142,410, which with the FILED `AllOther` 581 reach 231,370, the
-- filing's own revenue total, exactly. That marginal is offered to the ordinary partition search as
-- a flat candidate and survives only if it reconciles, exactly like a filed member.
--
-- THAT TEST IS THE WHOLE DESIGN, and the two poles show why nothing weaker works:
--
--   Chevron  a clean 2x2 grid; marginal + filed residual = the filing's total       -> served
--   Novo     its members NEST — Ozempic inside TotalGLP1 inside TotalDiabetesCare,
--            and EUCAN, CN, APAC and Emerging Markets all inside International
--            Operations. Summed flat its cells reach DKK 1,307,626m against revenue
--            of 309,064m, 4.2x. Only the disjoint level reconciles, and the existing
--            partition search finds it: US + International Operations = 309,064.     -> that level
--
-- No rule about grid shape or completeness separates those. Reconciliation does, and it is the rule
-- already relied on everywhere else in this parser.
--
-- Three guards fell out of the fixtures, each mutation-proven:
--   * a member the filer states FLATLY is never replaced by our sum — otherwise a disclosure gap
--     gets silently corrected to whatever we can add up;
--   * the marginal KEEPS the grid's qualifier — Chevron tags its cells
--     `ConsolidationItemsAxis = ReportableSegments`, whose total is 231,370m, while the bare
--     undimensioned revenue is a different figure; blanking it reconciled against the wrong total
--     and served nothing, which is what the first run against the real filing did;
--   * a marginal that earns NO partition is dropped rather than stored at 0 — a filed fact at
--     partition 0 is the filing speaking, but an unplaced marginal is ours and merely duplicates
--     the cells it came from. Alphabet's product cells sum to Google Services, not the company, so
--     five such rows would otherwise appear as a flat split the filer never made.

\set ON_ERROR_STOP on

-- GUARDED, for the reason migration 169 was not: an unconditional bump re-queues every filing on
-- EVERY deploy, which is how 94% of the served data came to be stale.
do $$ begin
  if not exists (select 1 from market.one_shot where key = 'segment-parser-cross-tab-marginals') then
    update market.segment_parser set version = version + 1;
    insert into market.one_shot (key) values ('segment-parser-cross-tab-marginals');
  end if;
end $$;

notify pgrst, 'reload schema';
