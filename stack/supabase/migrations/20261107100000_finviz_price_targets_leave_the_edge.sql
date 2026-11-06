-- FINVIZ PRICE TARGETS LEAVE THE EDGE (decided by the user 2026-11-06).
--
-- `security-price-targets` asked finviz, through openbb-api, for each US-listed company's analyst
-- actions. finviz moved its quote page on or around 2026-11-04 16:00 UTC: `/quote.ashx?t=AAPL`
-- now answers 301 to `/quote`, which ends at `/stock?t=AAPL` (200, 307 KB), and finvizfinance 1.5.0
-- still parses the old layout. openbb-api answers `400 Failed to get data for AAPL`, every run since
-- has advanced nothing, and `pending_price_targets` sat at 2,865 for every sample, which is what
-- `muffin-backlog-stalled` has been firing on. The resource behaved correctly (it called it an
-- outage and marked nothing); the data it serves is frozen at 11-04.
--
-- Per the user's rule the edge is not fixed; it retires. The replacement, also decided: analyst
-- actions from the `upgradeDowngradeHistory` the Dagster company lane already stores in every
-- Yahoo quoteSummary document (AAPL's holds 969 actions with the firm, both grades and both
-- targets, against finviz's 20), as a stage 2 over files on disk. Umbrella
-- docs/deferred/2026-11-05-finviz-moved-its-quote-page.md.
--
-- RETIRES: security-price-targets
--
-- The name is in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate. Its backlog
-- view goes now rather than with the handler, because nothing can reach the handler and the view is
-- what the stalled-backlog alert samples. `security_price_target` stays, as the app's table and the
-- replacement's target. tests/an-analyst-action-is-fetched-by-a-us-listing.sql, which asserted the
-- view's US-listing scope (a finviz limit Yahoo does not have), leaves with it.

update market.cron_resource set enabled = false where resource = 'security-price-targets';

delete from market.backlog_negative_cache where backlog = 'pending_price_targets';

do $$
declare k char;
begin
  -- relkind-aware: `drop view if exists` raises on a materialized view of the same name.
  select c.relkind into k
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_price_targets';
  if k = 'v' then
    execute 'drop view market.pending_price_targets';
  elsif k = 'm' then
    execute 'drop materialized view market.pending_price_targets';
  end if;
end $$;
