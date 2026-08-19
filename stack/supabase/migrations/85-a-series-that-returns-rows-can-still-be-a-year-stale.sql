-- A SERIES THAT RETURNS ROWS CAN STILL BE A YEAR STALE, AND TWO SERIES FOR ONE FACT IS WORSE THAN
-- NONE.
--
-- Migration 83 drove all 42 FRED candidates before seeding, precisely so a retired id could not be
-- seeded blind. It asked the wrong question. "Does this return rows?" is not "is this series still
-- being published", and it is not "does something else already answer this".
--
-- Measured in production 2026-08-19, after the first real run of `macro-indicators`
-- (2,137 observations written across 38 of 49 series):
--
--   1. TEN FRED CPI SERIES RETURN NOTHING. `CPALTT01USM659N` and its siblings end at 2025-04-01 —
--      the OECD-MEI CPI family on FRED stopped being updated. The seeding probe used
--      `start_date=2025-01-01` and saw 4 rows with "latest 2.311289", which read as current and was
--      April 2025. The resource asks for a 400-day window starting 2025-07-15, i.e. AFTER the last
--      observation, so it correctly gets zero and correctly reports `no data`.
--
--   2. `us-unemployment-fred` ANSWERS AND IS ELEVEN MONTHS OLD — latest 2025-09-01, against
--      `us-unemployment` (OECD) at 2026-07-01. It would have rendered on the US country page beside
--      the current one, both labelled "unemployment rate", differing with no way to tell which to
--      believe.
--
--   3. THE FRED SEED DUPLICATED WHAT MIGRATION 82 ALREADY HAD. US and Germany already had CPI, and
--      the US already had unemployment, from OECD. Adding a second series for the same
--      (country, category) does not add coverage — it puts two rows on one panel.
--
-- ── WHAT IS DISABLED, AND WHAT IS NOT ────────────────────────────────────────────────────────
--
-- Disabled rather than deleted: the row is the record that this id was tried and why it failed, and
-- deleting it invites the next person to re-add it. `enabled` is never touched by any seed's
-- `on conflict do update` (migration 82), so this survives every redeploy.
--
-- The FRED series that REMAIN are the ones that genuinely add coverage OECD does not: 10-year
-- government bond yields for 13 countries, and unemployment for 12 countries other than the US.
-- Those are current — Spain 2026-06-01, the UK 2026-04-01.
--
-- US `rates` deliberately keeps four series (10y yield, EFFR, SOFR, the yield curve). They are
-- different instruments, not four answers to one question, which is why the guard below is on
-- (country, category) for the categories where a duplicate is genuinely a contradiction rather
-- than on every category.

-- 1. The CPI family that stopped being published.
update market.macro_indicator
   set enabled = false,
       notes = 'FRED''s OECD-MEI CPI family stopped updating: last observation 2025-04-01, outside the resource''s 400-day window. Superseded by the OECD cpi route where one exists. Verified empty in production 2026-08-19.'
 where provider = 'fred'
   and params->>'symbol' like 'CPALTT01%';

-- 2. The stale duplicate.
update market.macro_indicator
   set enabled = false,
       notes = 'Eleven months stale (2025-09-01) while us-unemployment (OECD) is current (2026-07-01), and a duplicate of it. Two series for one fact on one panel is worse than one.'
 where code = 'us-unemployment-fred';

-- 3. Any FRED series that duplicates an ALREADY-ENABLED series for the same country and category.
--    Written as a rule rather than a list so a future seed cannot reintroduce the shape: OECD and
--    federal_reserve are the preferred providers because they are the ones publishing currently.
update market.macro_indicator f
   set enabled = false,
       notes = coalesce(f.notes, '') ||
         ' Disabled as a duplicate: another enabled series already covers this country and category.'
  where f.provider = 'fred'
    and f.enabled
    and f.category in ('inflation', 'labour', 'growth')
    and exists (
      select 1 from market.macro_indicator o
       where o.enabled
         and o.provider <> 'fred'
         and o.country_iso2 is not distinct from f.country_iso2
         and o.category = f.category
    );

comment on column market.macro_indicator.notes is
  'Why a series is disabled, kept instead of deleting the row — the record that an id was tried and failed is what stops the next person re-adding it. Never cleared by a seed''s on-conflict.';

notify pgrst, 'reload schema';
