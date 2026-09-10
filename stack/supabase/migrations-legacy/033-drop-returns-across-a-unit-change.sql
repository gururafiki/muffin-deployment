-- Remove returns measured ACROSS a currency redenomination or unadjusted corporate action.
--
-- These are the provider's numbers, faithfully stored — and still not real. Measured 2026-08-12 by
-- re-fetching the daily series for all 40 securities with a 1y return >= +300% and taking each
-- one's largest single-day ratio. The two populations separate with nothing in between:
--
--   discontinuous   AMRM.TA 96.6x   ISHO.TA 101.0x   ARZTF 30.3x
--                   PBMRF 28.7x     YZOFF 25.5x      KLTHF 6.0x
--   real            ASAAF 2.04x  KXHCF 1.45x  009150.KS 1.30x  SNDK 1.28x  MU 1.19x  INTC ...
--
-- AMRM.TA and ISHO.TA jump ~100x on THE SAME DAY (2026-05-18) and are both quoted in `ILA`: Yahoo
-- switched Tel Aviv quotes from shekels to agorot. The USD names are OTC lines carrying an
-- unadjusted ratio change. A reverse split looks identical and is equally not comparable.
--
-- The 34 smooth ones are LEFT ALONE. SNDK really is up ~2,700% and MU ~580%; clipping those would
-- replace a right number with a different wrong one. What is untrustworthy is a return measured
-- across the break, which is exactly and only what goes.
--
-- `returnsFor` now omits any period whose anchor predates the most recent >5x move, so nothing
-- writes these again. But AN UPSERT CANNOT RETRACT: rows already stored for periods the resource
-- no longer produces would survive every future refresh looking freshly written. The handler now
-- deletes non-produced periods per symbol; this clears what is there today, including for the
-- securities whose series the provider may stop answering for entirely.
--
-- Deleting rather than nulling: an absent row is already how this schema says "no number", and the
-- UI renders that honestly. A stored null would claim we looked and there was nothing.
--
-- Safe to re-run: after the code fix the rows do not come back, and the predicate simply matches
-- nothing. Named securities rather than a blanket threshold on purpose — a large return is not by
-- itself wrong, and deleting every big number would discard the 34 real ones.

delete from market.performance p
 where p.scope = 'instrument'
   and p.scope_id in ('AMRM.TA', 'ISHO.TA', 'ARZTF', 'PBMRF', 'YZOFF', 'KLTHF');
