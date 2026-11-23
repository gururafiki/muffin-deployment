-- UPDATE-HEAVY TABLES ARE VACUUMED BEFORE THEIR VISIBILITY MAPS GO STALE.
--
-- The twice-daily coverage sample (`muffin-coverage`) took 136, 149 and 183 s on the mornings of
-- 2026-11-21..23 and was cancelled at its 300 s bound at 17:23 on 11-22 and 11-23. Its presence
-- flags are `SELECT DISTINCT security_id` reads, which Postgres answers with index-only scans, and
-- an index-only scan is only cheap where the visibility map says a page is all-visible. Measured
-- 2026-11-23 on `security_filing`: 1,244,767 rows, **610,736 heap fetches**, 9.4 s warm and 122.8 s
-- cold. A plain VACUUM took 11 s, after which the same read made **71** heap fetches in 0.26 s.
--
-- These tables are UPDATED far more than they are inserted into: a CNINFO re-queue rewrites
-- thousands of `security_filing` rows, a re-derivation moves `security_metric.fetched_at` (14.4 M
-- updates, none HOT), and a re-parse rewrites segments. At the default scale factor of 20%,
-- autovacuum waits for 1.66 M dead tuples in `security_metric` before it starts. On 2026-11-23:
--
--   table                dead tuples   all-visible   last vacuum
--   security_metric        1,339,959       35%          11-04
--   security_segment         154,496       33%          11-20
--   security_statement       107,921       93%          11-19  (319,251 heap fetches in one read)
--   fiscal_period             76,762       45%          11-10
--   security_filing          193,901        —           11-07  (vacuumed by hand, 11-23 21:5x)
--
-- 2% instead of 20%, for dead tuples and for inserts alike, the second as `insider_trade` got on
-- 2026-11-08. Each of the first four exceeds its new threshold now, so autovacuum takes them within
-- minutes of this migration. `price_bar`'s year partitions (about 60% all-visible since the
-- October rewrites) are left: a partitioned parent passes no storage parameter to its partitions,
-- and nothing reads them index-only.

alter table market.security_filing
  set (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.02);
alter table market.security_metric
  set (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.02);
alter table market.security_segment
  set (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.02);
alter table market.security_statement
  set (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.02);
alter table market.fiscal_period
  set (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.02);
