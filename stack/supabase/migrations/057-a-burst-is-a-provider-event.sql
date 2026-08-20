-- 2,445 STATEMENTS MARKS WERE SET IN THREE BURSTS, AND A BURST IS A PROVIDER EVENT.
--
-- Same incident as migration 55, a different negative cache, and found only because 55 prompted
-- the question "which other marks are false?". `performance_missing_at` could be settled by
-- contradiction — `security-prices` was writing daily bars for the same securities off the same
-- endpoint. `statements_missing_at` has no such contradiction available: a security marked as
-- having no statements has no statements, so holding the data cannot disprove the mark.
--
-- THE RATE DISPROVES IT INSTEAD. Measured 2026-08-14 over all 2,618 marks:
--
--   2026-08-11 18:00    518          three bursts, 2,445 marks
--   2026-08-11 19:00    725
--   2026-08-12 15:00  1,032
--   2026-08-13 onward  1-24 / hour   steady state, ~15/hour
--
-- Marking a thousand securities in one hour, at seventy times the rate the same resource sustains
-- on either side of it, is not the discovery that a thousand blue chips stopped filing accounts.
-- It is yfinance refusing — which it does by answering 200 WITH NO ROWS rather than erroring, so
-- `security-statements`' gate (`anyAnswer || (failed === 0 && written > 0)`) stays satisfied by
-- whichever securities it was still answering for.
--
-- CONFIRMED BY DRIVING THE PROVIDER, not inferred from the rate alone. `security-refresh` against
-- ISRG, EXC and MLM — all marked in the 08-11 burst — returned **12 rows of statements each**,
-- today. 85 of the 221 securities that are a >=1.5% holding of a sector fund were marked: Exelon,
-- Intuitive Surgical, Martin Marietta, Essex Property Trust, International Flavors & Fragrances.
--
-- WHY THE MEGA-CAP CANARY SAW NOTHING, which is the part worth keeping. It reported
-- `statements_missing_at = 0 of 213` the same morning, because it filters on
-- `country_iso2 = 'US' and market_cap > 50e9`, and every one of these sits in one of its three
-- blind spots: ISRG had NO market cap at all (34% of the universe does not), EXC/MLM/ESS are
-- below $50bn, and Chubb is Swiss. A canary keyed on market cap cannot see a universe that is
-- two-thirds uncapped and mostly not American. `market-verify` now also checks securities by
-- FUND WEIGHT, which is a percentage and therefore free of currency, cap and country.
--
-- The cutoff is 2026-08-13 00:00Z: the gates that stop this landed that day, and everything
-- before it is contaminated. Over-clearing is the cheap direction — a security whose mark was
-- honest is asked once more and marked again, while a false mark costs 30 days of exclusion.
--
-- ONE-SHOT: this is a repair of a specific window, not a policy. Re-running it every deploy would
-- clear marks earned honestly after the window and defeat the cache it is repairing.

do $$
declare
  cleared bigint;
begin
  if exists (select 1 from market.one_shot where key = '57-clear-throttle-burst-statement-marks') then
    return;
  end if;

  update market.security
     set statements_missing_at = null
   where statements_missing_at is not null
     and statements_missing_at < timestamptz '2026-08-13 00:00:00+00';

  get diagnostics cleared = row_count;

  insert into market.one_shot (key, reason) values
    ('57-clear-throttle-burst-statement-marks',
     format('Cleared %s statements_missing_at marks set before 2026-08-13, when three bursts '
            || '(518 + 725 + 1032 in one hour each, against a ~15/hour steady state) recorded '
            || 'securities as having no statements during yfinance throttling. ISRG, EXC and MLM '
            || 'each returned 12 rows when re-driven.', cleared));
end $$;

notify pgrst, 'reload schema';
