-- GDP IS MONEY, AND CALLING IT AN INDEX MADE IT UNREADABLE.
--
-- `us-gdp-real` was seeded in migration 82 with `unit = 'index'`. That was a guess, and it was
-- wrong. Measured against the deployed openbb-api 2026-08-19:
--
--   economy/gdp/real    oecd  united_states  2026-04-01  25,575,729,500,000
--   economy/gdp/nominal oecd  united_states  2026-04-01  32,475,210,000,000
--
-- Those are USD LEVELS — ~$25.6tn real and ~$32.5tn nominal, which are the right magnitudes for US
-- GDP. Not an index, not millions.
--
-- The consequence was visible rather than theoretical: the country panel renders a value it cannot
-- name as a bare number, so the US page printed `25575729500000`. Honest and useless. With the unit
-- corrected the same figure reads `$25.58T` through the existing CLDR money formatter.
--
-- ── `unit` NOW HOLDS A CURRENCY CODE WHERE THE VALUE IS MONEY ────────────────────────────────
--
-- Rather than a boolean "is money", because OECD returns GDP in each country's NATIONAL currency —
-- a German series would be EUR, not USD. The three-letter code is the fact the formatter needs and
-- the one that stops the next reader assuming dollars. Only the US series is seeded today, and its
-- currency is measured, not assumed.
--
-- `gold`, `oil-wti` and `btc` were already `usd` and are already correct; `sp500` stays `index`
-- because an index level genuinely is not money.

update market.macro_indicator
   set unit = 'usd',
       notes = coalesce(notes || ' ', '') ||
         'Unit corrected from `index` to `usd` 2026-08-19: OECD gdp/real returns a USD LEVEL (25,575,729,500,000 = ~$25.6tn), not an index. Measured, not inferred.'
 where code = 'us-gdp-real';

comment on column market.macro_indicator.unit is
  'How to render the value. `percent` for a rate, `index` for a genuine index level, or a THREE-LETTER CURRENCY CODE where the value is money — OECD returns GDP in each country''s national currency, so this cannot be a boolean and must not default to dollars.';

notify pgrst, 'reload schema';
