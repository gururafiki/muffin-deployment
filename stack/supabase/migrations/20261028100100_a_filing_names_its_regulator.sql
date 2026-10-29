-- A FILING NAMES ITS REGULATOR. Phase 5 step 4 of the umbrella's docs/specs/2026-10-24-sec-family.md
-- (decision 13, the user, 2026-10-25).
--
-- `security_filing.source_code` holds the RESOURCE that wrote a row (`sec-submissions`,
-- `sec-filings`), while `filing_form` is keyed by the REGULATOR (`sec`, `dart`, `nse`, `cninfo`), so
-- every reader that asks which regulator a filing belongs to joins through a form code. Scoping on the
-- writer's code instead has already emptied a backlog once (`source_code = 'sec'` matches no row).
-- `disclosure_source_code` names the regulator on the row.
--
-- WRITTEN BY THE DAGSTER WRITERS ONLY. The edge's rows keep it null: the edge is neither kept
-- working nor fixed (the user, 2026-10-25), and its filings resources retire at step 9. Nothing
-- reads the column yet; the segments queue moves onto it in Phase 6.
--
-- Guard: stack/supabase/tests/company-facts-read-their-own-concepts.sql.

alter table market.security_filing
  add column if not exists disclosure_source_code text references market.disclosure_source (code);

comment on column market.security_filing.disclosure_source_code is
  'The regulator the filing was made with (market.disclosure_source). source_code is the resource '
  'that wrote the row. Null on rows the edge wrote.';
