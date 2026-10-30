-- THE RETIRED PRICE AND UNIVERSE TABLES ARE DROPPED. The table half of
-- docs/deferred/2026-09-30-the-retired-families-leave-columns-behind.md (umbrella), due on or after
-- 2026-10-12; the columns on `security` and `currency` follow in their own migration.
--
-- Expand/contract: these were kept as a backup while the Dagster lanes that replaced them ran.
--   - `security_price` (5.3 GB): written by the retired `security-prices`, `-price-history` and
--     `-daily-history`; `price_bar` has served every reader since the D2 cutover (2026-09-12).
--   - `prices`: written by the retired `instrument-prices`.
--   - `exchange_listing` (54 MB) and `exchange_cursor`: written by the retired `exchange-listings`;
--     `venue_listing` replaced them in Phase 3 step 5. NOT `exchange_label`,
--     `exchange_sweep_partition` or `exchange_sweep_type`, which are live control tables of the
--     Dagster discovery lane.
--
-- Checked on production 2026-10-30 before writing: no view depends on any of them (pg_depend), no
-- `market` function reads them (the only matches were comments), and neither muffin-ui, muffin-ingest
-- nor a Grafana panel names them. The last readers were a market-verify count of the retired
-- `performance_missing_at` gauge and a test of legacy migration 055, both removed in this change.
--
-- WHY NOW: `/mnt/data` reached 78% (the alert fires at 80%) with Phase 5's backfills still to land.

drop table if exists market.security_price;
drop table if exists market.prices;
drop table if exists market.exchange_listing;
drop table if exists market.exchange_cursor;
