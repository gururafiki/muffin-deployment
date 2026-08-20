-- Returns of exactly 0.00% over a quarter or more — IDEMPOTENT.
--
-- These are the delisted-instrument signature. The price provider keeps serving a dead security's
-- final bars, so every period is measured between two identical closes and stores +0.00%, which
-- renders as "flat" rather than "gone". Measured 2026-08-13: **212 rows** across 3m/6m/1y, including
-- the country scopes for Egypt, Nigeria and Portugal (already removed by migration 46) and OTC
-- foreign-ordinary lines such as INREF, GUOSF and HUATF that barely trade.
--
-- `returnsFor` now refuses any series whose last bar is over ten days old, so nothing writes these
-- again. But the stored rows do NOT heal: once a security stops producing a series the refresh has
-- nothing to overwrite them with, and the delete-stale-periods step only runs for symbols that
-- returned rows.
--
-- WHY THE LONG PERIODS ONLY. A day, a week or a month really can close exactly flat — thin
-- securities do it, and deleting those would be discarding real data. Over a quarter it takes a
-- suspension or a delisting, and over a year essentially only a dead series. `1d`/`1w`/`1m` are
-- deliberately left alone.
--
-- Safe to re-run: after the staleness guard the predicate matches nothing, and `market-verify`
-- check 7f fails first if it ever matches more than five again.

delete from market.performance
 where period in ('3m', '6m', '1y', '3y', '5y')
   and change_pct = 0;
