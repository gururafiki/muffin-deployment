-- THE EDGE'S SEGMENT QUEUES DROP (Phase 6 step 9).
--
-- Seven views fed the edge's segment parsers and filing walkers: `pending_segments`,
-- `pending_{kr,in,cn}_segments`, `pending_{kr,in}_history` and `pending_cn_filings`. Their
-- resources answer 410 since their Dagster lanes went live (SEC 2026-11-14; CNINFO, DART and NSE
-- 2026-11-16), and their handlers were deleted on 2026-11-20 (step 8). The lanes keep their own
-- queues, as asset checks and partition status, so nothing reads these views but two things that
-- would rather not:
--
--   * `backlogs_to_sample()` samples every `pending_%` view twice an hour. Measured 2026-11-20,
--     `pending_cn_segments` (31,169) and `pending_kr_history` have been FLAT since their resources
--     retired, and "A non-empty backlog has been FLAT for a week" has fired on them since. Dropping
--     the views is the fix: `backlog_drain` drops a subject that is no longer sampled (#480).
--   * `pending_segments` scans the 1.2 M-row filing table and timed out at the 8 s ceiling on 17%
--     of the edge's runs (Phase 6's reason to exist); nothing should be able to call it again.
--
-- Views hold no data, so they go now. The state the walkers WROTE stays as a backup, with a drop
-- date, as the earlier families' columns did (`docs/deferred/2026-09-30-the-retired-families-leave-
-- columns-behind.md`): `market.dart_discovery_cursor` (1 row), `security_filer.history_walked_at`
-- (3,244 rows set) and `security.nse_history_walked_at`. Nothing reads them: measured 2026-11-20,
-- no view depends on them and the only function naming one (`apply_nse_symbol_map`) does so in a
-- comment.
--
-- No dependents: measured 2026-11-20 through pg_rewrite, no view or matview reads any of the seven.

drop view if exists market.pending_segments;
drop view if exists market.pending_kr_segments;
drop view if exists market.pending_in_segments;
drop view if exists market.pending_cn_segments;
drop view if exists market.pending_kr_history;
drop view if exists market.pending_in_history;
drop view if exists market.pending_cn_filings;

-- `backlog_negative_cache` pairs a backlog with the negative cache that marks its rows; a row for a
-- view that no longer exists names nothing.
delete from market.backlog_negative_cache where backlog = 'pending_segments';
