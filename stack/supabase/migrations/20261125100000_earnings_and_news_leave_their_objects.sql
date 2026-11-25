-- EARNINGS AND NEWS LEAVE THEIR OBJECTS (Phase 6b step 7; umbrella
-- docs/specs/2026-11-21-macro-and-events.md, "Contract, with a drop date").
--
-- The edge resources `earnings-calendar`, `earnings-history`, `security-news` and
-- `macro-indicators` answer 410 since 2026-11-22 (20261122110000, 20261122120000), and their
-- handlers leave `market-refresh` in the same change as this migration. The Dagster lanes served
-- three clean days first, read 2026-11-25: every `yahoo_companies`, `nasdaq_earnings_window` and
-- `macro_daily` run SUCCESS, `news_is_current` and `nasdaq_window_is_current` passing, 905 news
-- links published in three days against market-verify's floor of 100.
--
-- WHAT GOES, each kept as a backup under expand/contract until now:
--   - `pending_news`: the edge's news backlog, read only by the deleted handler;
--   - `security.news_fetched_at`: its cursor, read only by `pending_news`;
--   - `earnings_history_cursor`: the edge's walk through nasdaq's history, stalled at 2016-06-30
--     since 2026-09-06; the nasdaq lane partitions by day instead;
--   - `security_earnings_surprise`: one quarter's surprise from nasdaq's consensus. muffin-ui
--     reads `security_earnings_history` since #144 (2026-11-21), and its smoke asserts the old
--     view is no longer asked.
--
-- MEASURED ON PRODUCTION 2026-11-25: `pg_depend` names one dependent of these, `pending_news` on
-- the column. No function in `market`, `api` or `ingest` mentions any of them. muffin-ui,
-- muffin-ingest (a docstring only), muffin-agent, Grafana and the workflows read none of them.
-- Their four `cron_resource` rows stay disabled, as every retirement's have.

drop view if exists market.pending_news;
drop view if exists market.security_earnings_surprise;
drop table if exists market.earnings_history_cursor;
alter table market.security drop column if exists news_fetched_at;
