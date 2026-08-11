-- Remove returns that say a security lost EVERYTHING — IDEMPOTENT.
--
-- These were never market events. `returnsFor` guards a zero denominator (`from === 0`) but not the
-- numerator, and `Number.isFinite(0)` is true, so a provider bar with `close: 0` as the latest
-- point made every period compute `(0 / from - 1)` = exactly -100%.
--
-- Measured 2026-08-11: 1,078 of 20,399 `performance` rows, i.e. 154 securities each carrying -100%
-- on ALL SEVEN periods including `1d`. A security cannot fall 100% in a day and also 100% over a
-- year. They cluster in late timezones — India 50, Taiwan 36, mainland China 34, Hong Kong 8,
-- Korea 3 — plus 22 US listings: an untraded or not-yet-reported session, not 154 bankruptcies.
--
-- The parse now drops non-positive closes (`barFrom` in market-refresh/resources.ts), so nothing
-- writes these again. The rows already stored do NOT heal on their own: a security whose only bars
-- are zeros now yields a series shorter than two bars and is skipped entirely, so its stale -100%
-- would sit there permanently with nothing to overwrite it.
--
-- Deleting rather than nulling: `performance` is a cache keyed on (scope, scope_id, period), and an
-- absent row is exactly how this schema already says "no number for this period" — which is what
-- the UI renders honestly. A stored null would be a claim that we looked and there is nothing,
-- which is not the same thing.
--
-- Safe to re-run on every deploy: after the parse fix the predicate matches nothing. If it ever
-- matches again, `market-verify.yml` check 7c fails first and says so.

delete from market.performance
 where scope = 'instrument'
   and change_pct = -100;
