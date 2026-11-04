-- AN AMENDED FORM 4 SUPERSEDES THE LINES IT RESTATES (decided by the user 2026-11-04).
--
-- A Form 4/A amends a Form 4 already filed. `insider_trade` keeps both, keyed by accession and line
-- (a restatement stays visible), and `security_insider_summary` counted both. Measured on production
-- 2026-11-04: 474 original Form 4 lines from the Form 4 lane (183 filings, 431 inside the summary's
-- 90-day window) have a 4/A filed on or after them for the same security, owner and transaction day.
--
-- THE KEY IS NARROWER THAN THE DECISION'S WORDING, BECAUSE AN AMENDMENT CAN RESTATE ONLY THE LINES
-- IT CORRECTS. The decision read "a later 4/A for the same issuer, owner and transaction date".
-- Measured, it would also drop lines no amendment mentions:
--   - an owner's 4/A of 2026-09-03 restates only the derivative grant (30,864 -> 31,397 shares)
--     and leaves the same day's 11,626-share open-market purchase at 129.02 standing;
--   - an owner's three 4/As of 2026-11-02 each restate only line nd:1 of a Form 4 whose other lines
--     (80, 8,571 and 14,032 shares, indirect holdings) stand.
-- So a line is superseded only by an amendment line of the same security, owner, transaction day,
-- derivative flag and transaction code: 350 lines in the window rather than 431. The 81 kept are
-- lines the amendment does not restate. 14 lane groups still hold more original lines than
-- amendment lines at that key (a partial restatement within one code); the XML carries no per-line
-- link to the original, so nothing narrower is available.
--
-- "Later" is a 4/A filed on or after the original: an amendment filed BEFORE a Form 4 amends an
-- earlier filing, not that one. Only originals are skipped, as decided; a 4/A superseded by a later
-- 4/A (2 lane lines) and a Form 5 superseded by a 5/A (173 data-set lines, all of 2006-07, outside
-- the window) are not.
--
-- The gate is written positively (`is distinct from '4' or not exists`) so a row with no form type,
-- the edge's, falls through to COUNTED rather than to a NULL that drops it.
-- Guard: tests/an-amended-form-4-supersedes-the-lines-it-restates.sql.

create or replace view market.security_insider_summary as
WITH lane_days AS MATERIALIZED (
         SELECT DISTINCT insider_trade.filing_date
           FROM market.insider_trade
          WHERE insider_trade.accession_number IS NOT NULL AND insider_trade.filing_date >= (CURRENT_DATE - 90)
        )
 SELECT security_id,
    count(*) FILTER (WHERE direction = 'Acquisition'::text) AS buys,
    count(*) FILTER (WHERE direction = 'Disposition'::text) AS sells,
    count(DISTINCT owner_name) FILTER (WHERE direction = 'Acquisition'::text) AS buyers,
    count(DISTINCT owner_name) FILTER (WHERE direction = 'Disposition'::text) AS sellers,
    COALESCE(sum(shares) FILTER (WHERE direction = 'Acquisition'::text), 0::numeric) - COALESCE(sum(shares) FILTER (WHERE direction = 'Disposition'::text), 0::numeric) AS net_shares,
    max(transaction_date) AS latest,
    count(*) AS trades
   FROM market.insider_trade t
  WHERE transaction_date >= (CURRENT_DATE - 90) AND (accession_number IS NOT NULL OR NOT (EXISTS ( SELECT 1
           FROM lane_days d
          WHERE d.filing_date = t.filing_date)))
    AND (t.form_type IS DISTINCT FROM '4'::text OR NOT (EXISTS ( SELECT 1
           FROM market.insider_trade a
          WHERE a.security_id = t.security_id AND a.owner_cik = t.owner_cik
            AND a.transaction_date = t.transaction_date AND a.is_derivative = t.is_derivative
            AND a.transaction_code = t.transaction_code AND a.form_type = '4/A'::text
            AND a.filing_date >= t.filing_date)))
  GROUP BY security_id;
