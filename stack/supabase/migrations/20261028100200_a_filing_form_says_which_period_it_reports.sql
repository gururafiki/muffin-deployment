-- A FILING FORM SAYS WHICH PERIOD IT REPORTS. Phase 5 step 4 of the umbrella's
-- docs/specs/2026-10-24-sec-family.md.
--
-- The fiscal calendar (`facets/fiscal.py` in muffin-ingest) is built from the registrant's own
-- reports: each annual report's `reportDate` is a year end, each transition report's a short year,
-- each quarterly report's a quarter end. Which forms are which lived only in the measurement
-- harness (2026-10-26/27). It belongs here, with the rest of what the SEC lane knows about a form:
--   - `annual`: 10-K, 20-F, 40-F;
--   - `transition`: 10-KT (Mistras's 7 months, Greif's 11, Bristow's 9);
--   - `interim`: 10-Q, 10-QT.
-- Amendments have none: an amendment restates a period the original already gave. Nor does 6-K,
-- which carries monthly revenue as often as results and no quarterly XBRL.
--
-- Guard: stack/supabase/tests/company-facts-read-their-own-concepts.sql.

alter table market.filing_form
  add column if not exists fiscal_role text check (fiscal_role in ('annual', 'transition', 'interim'));

comment on column market.filing_form.fiscal_role is
  'The period a filing of this form reports, for the fiscal calendar: annual, transition or '
  'interim. Null for amendments and for forms that report no period.';

update market.filing_form
   set fiscal_role = case form_code
                       when '10-K' then 'annual'
                       when '20-F' then 'annual'
                       when '40-F' then 'annual'
                       when '10-KT' then 'transition'
                       when '10-Q' then 'interim'
                       when '10-QT' then 'interim'
                     end
 where source_code = 'sec'
   and fiscal_role is distinct from case form_code
                                      when '10-K' then 'annual'
                                      when '20-F' then 'annual'
                                      when '40-F' then 'annual'
                                      when '10-KT' then 'transition'
                                      when '10-Q' then 'interim'
                                      when '10-QT' then 'interim'
                                    end;
