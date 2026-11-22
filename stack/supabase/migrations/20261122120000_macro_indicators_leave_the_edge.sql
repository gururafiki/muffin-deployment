-- MACRO LEAVES THE EDGE: `macro-indicators` retires, replaced by the Dagster macro lane (Phase 6b
-- step 4, umbrella docs/specs/2026-11-21-macro-and-events.md).
--
-- RETIRES: macro-indicators
--
-- THE REPLACEMENT is `raw_macro_series` → `macro_observation` (muffin-ingest#190): one partition per
-- enabled row of `market.macro_indicator`, asked daily at 07:40 UTC through openbb in-process, the
-- same providers and routes the edge used through openbb-api.
--
-- Measured before retiring it, read-only on production (2026-11-21): 37 of 38 enabled series
-- answered; 2,146 of 2,147 points identical to what the edge had written (the other was that day's
-- bitcoin price), no inserts. The lane also RETRACTS within each answer's window, which the edge's
-- upsert could not: 18 weekend and holiday gold and oil bars Yahoo no longer returns.
--
-- The rotation row is disabled, and `market-refresh` answers 410 naming the lane. The handler goes
-- with the other three in the contract step (Phase 6b step 7).

update market.cron_resource
   set enabled = false
 where resource = 'macro-indicators';
