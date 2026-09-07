-- ASC 280 REQUIRES LONG-LIVED ASSETS BESIDE REVENUE, AND IT WAS ALREADY IN EVERY INSTANCE WE READ.
--
-- Measured 2026-09-06 by enumerating every concept on a segment axis in Amazon's FY2022 10-K
-- (2.46 MB, 98 dimensioned segment contexts). Beyond the six the parser takes, the document
-- carries:
--
--     us-gaap:NoncurrentAssets     US $180,000,000,000 / non-US $61,300,000,000, INSTANTS on
--                                  `StatementGeographicalAxis` — exactly the geographic long-lived
--                                  assets ASC 280 mandates beside geographic revenue
--     us-gaap:Goodwill             per segment, which is where impairment is tested
--
-- SEC's frames API puts them at **722** and **3,347** filers for CY2022. Both are ordinary
-- balance-sheet lines with a real company-level meaning, which matters because `xbrl_concept` is
-- SHARED with `security-xbrl` and adding a concept here also fetches it for the whole universe.
--
-- THAT COST WAS MEASURED RATHER THAN ASSUMED, because migration 146 records it as the reason two
-- concepts were deliberately NOT added. `security_metric` holds 3,552,556 rows across 27 metrics;
-- `total_assets` — the closest analogue, also an instant — accounts for 48,322 of them across
-- 3,519 CIK-holding securities. Scaled by adoption these two add roughly 10,000 and 46,000 rows,
-- under 2% growth in total. Not material, which is why they ship and migration 146's two did not.
--
-- NO PARSER VERSION BUMP, for the reason migration 191 gives: the corpus is mid-drain, so the
-- filings still queued pick these concepts up on the pass they are already making. A bump would
-- restart a month-long drain to reach the few thousand already re-read.

insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order) values
  -- A STOCK, NOT A FLOW — `is_flow` is what `derive_ttm` sums on, and summing four quarters of a
  -- balance-sheet line would report four times the assets.
  ('long_lived_assets', 'Long-lived assets', 'balance_sheet', 'currency', false, false, 131),
  ('goodwill',          'Goodwill',          'balance_sheet', 'currency', false, false, 132)
on conflict (code) do update
  set name = excluded.name, category = excluded.category, unit = excluded.unit,
      is_flow = excluded.is_flow, is_derived = excluded.is_derived;

-- ONE ROW PER CONCEPT NAME, AND IFRS IS COVERED FOR SEGMENTS BUT NOT AT COMPANY LEVEL.
--
-- IFRS spells both of these exactly as us-gaap does, and `xbrl_concept`'s primary key is
-- (metric_code, concept) with no taxonomy in it — so a row per taxonomy is the SAME KEY TWICE and
-- fails the whole statement with SQLSTATE 21000, which is how the first version of this migration
-- died. That is the fourth instance of that shape recorded in CLAUDE.md and it caught me anyway.
--
-- One row is nonetheless the right answer for what this is FOR. The segment parser matches on the
-- LOCAL name (`parseFacts` does `byConcept.get(local(tag))`), so a single row reads
-- `us-gaap:NoncurrentAssets` and `ifrs-full:NoncurrentAssets` alike and the geographic split — the
-- thing ASC 280 mandates and the reason this migration exists — works for both.
--
-- The COMPANY-LEVEL series does not. `security-xbrl` looks the concept up under
-- `companyfacts[taxonomy]`, so with `us-gaap` here an IFRS filer contributes no company-level
-- long-lived assets or goodwill. That is a real gap and it is stated rather than hidden: closing it
-- means putting taxonomy in the primary key, which is a schema change with its own blast radius and
-- no bearing on the segment split this ships for.
insert into market.xbrl_concept (metric_code, concept, priority, unit, taxonomy) values
  ('long_lived_assets', 'NoncurrentAssets', 100, 'USD', 'us-gaap'),
  ('goodwill',          'Goodwill',         100, 'USD', 'us-gaap')
on conflict (metric_code, concept) do update
  set priority = excluded.priority, unit = excluded.unit, taxonomy = excluded.taxonomy;

-- ── AND THE STATEMENT VOCABULARY, WHICH THE GUARD IS RIGHT TO DEMAND ───────────────────────────
--
-- `two-providers-do-not-share-a-vocabulary` requires every non-derived metric to be reachable from
-- BOTH statement providers, because a metric with no row for one of them silently disappears for
-- half the data. It failed this migration, correctly: adding a metric code without its provider
-- spellings is exactly the inert-column shape.
--
-- Measured on the deployed openbb-api rather than guessed, and the spellings differ in the way this
-- table exists for:
--
--     sec       total_noncurrent_assets     goodwill
--     yfinance  total_non_current_assets    goodwill
--
-- One underscore, like `total_pretax_income` / `total_pre_tax_income` — it reads as a typo and
-- "correcting" it empties the series for whichever provider was changed.
--
-- I FIRST CONCLUDED YFINANCE HAD NO GOODWILL FIELD AT ALL, having probed with AAPL — which carries
-- essentially none, so openbb omitted the null key. MSFT and CRM both return it. That is this
-- file's own rule (probe with symbols you expect to FAIL) inverted: I probed with a symbol whose
-- VALUE is absent and concluded the FIELD was.
insert into market.metric_source_field (metric_code, source_code, statement, field) values
  ('long_lived_assets', 'sec',      'balance', 'total_noncurrent_assets'),
  ('long_lived_assets', 'yfinance', 'balance', 'total_non_current_assets'),
  ('goodwill',          'sec',      'balance', 'goodwill'),
  ('goodwill',          'yfinance', 'balance', 'goodwill')
on conflict (metric_code, source_code) do update
  set statement = excluded.statement, field = excluded.field;

notify pgrst, 'reload schema';
