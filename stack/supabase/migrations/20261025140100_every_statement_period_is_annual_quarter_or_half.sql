-- EVERY STATEMENT PERIOD IS ANNUAL, QUARTER OR HALF (Phase 5 step 2b, second file).
--
-- Validates the CHECK 20261025140000 added NOT VALID. On its own file because a migration file is
-- one transaction: VALIDATE takes only SHARE UPDATE EXCLUSIVE, which lets reads and writes go on
-- while it scans, but inside the previous file it would have scanned under that file's ACCESS
-- EXCLUSIVE lock from the key swap, blocking the app's statement reads for the whole scan.

alter table market.security_statement validate constraint security_statement_period_type_check;
