-- TIINGO LEAVES THE EDGE (Phase 4 decision 9, decided by the user 2026-10-25).
--
-- `security-corporate-actions` asked Tiingo for dividends and splits by US ticker. The Dagster price
-- lane's `yahoo_corporate_action` states both from the chart documents it already stores, for
-- 10,081 securities against Tiingo's 388. The parity check decision 9 waited for, run 2026-10-25
-- from Yahoo's stored documents over all 388:
--   * dividends: 6,823 Tiingo rows; Yahoo states 5,828 on the same day and value, 141 within five
--     days, 732 on the same day with ANOTHER value, 80 not at all, 42 outside Yahoo's span;
--   * splits: 91; Yahoo states 80 on the same day and value; the other 11 are distributions of
--     1.01-1.05, not splits.
-- The 732 are split adjustment: Tiingo's dividends are as paid, Yahoo's are split-adjusted like the
-- closes `security_return` reinvests them against, so AVGO's 5y total return was served as
-- +1,140.7% against a +527.2% price return. muffin-ingest#126 lets Yahoo's rows replace Tiingo's on
-- the days Yahoo states; the 133 rows only Tiingo holds stay until the contract.
--
-- The resource had also stalled: from 2026-10-22 every hourly run asked the same 60 securities,
-- recorded nothing for an empty answer, and left `pending_corporate_actions` at 1,035, which is
-- what `muffin-backlog-stalled` was firing on. Per the user's rule the edge is not fixed; it retires.
--
-- RETIRES: security-corporate-actions
--
-- The name is in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate. Its backlog
-- view goes now rather than with the handler, because nothing can reach the handler and the view
-- is what the stalled-backlog alert samples. `security.corporate_actions_missing_at`, the Tiingo
-- token and the handler leave at the contract
-- (umbrella docs/deferred/2026-09-30-the-retired-families-leave-columns-behind.md).
-- tests/an-action-must-match-the-price-series.sql, which asserted the view's population, leaves
-- with it.

update market.cron_resource set enabled = false where resource = 'security-corporate-actions';

delete from market.backlog_negative_cache where backlog = 'pending_corporate_actions';

do $$
declare k char;
begin
  -- relkind-aware: `drop view if exists` raises on a materialized view of the same name.
  select c.relkind into k
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_corporate_actions';
  if k = 'v' then
    execute 'drop view market.pending_corporate_actions';
  elsif k = 'm' then
    execute 'drop materialized view market.pending_corporate_actions';
  end if;
end $$;
