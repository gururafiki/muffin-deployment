-- ADDING A VENUE MUST CLEAR THE MARKS SET WHILE IT WAS MISSING. Migration 63 did not, and quoted
-- the very lesson it then failed to apply.
--
-- 63 added Ho Chi Minh, Hanoi, Kuwait, Doha and Buenos Aires to `market.exchange` so their
-- securities could finally resolve a symbol. Sweeping them worked immediately — VN 1,617, VM 409,
-- KK 145, QD 56, AR 213, every count matching what `/v3/filter` had predicted. And the securities
-- stayed symbol-less, because `security-tickers` had already given up on them:
--
--   Kuwait   38 of 40 carry figi_missing_at
--   Qatar    33 of 35
--   Vietnam  57 of 57
--
-- The mark is honest about what happened: OpenFIGI answered, returned listings on `KK`, `QD` and
-- `VN`, and none of those was a venue this pipeline knew — so no acceptable listing was found and
-- the security was recorded as unresolvable. What it cannot express is that the answer depended on
-- OUR venue catalogue, which has now changed. `security-local-symbols` reports
-- `remaining: 0, "no addressable securities pending"` and will never revisit them.
--
-- This is the Taiwan bug in a new place, and migration 63's own comment cites it: "A negative cache
-- can memorise your own bug. Taiwan's 534 were marked `local_symbol_missing_at` by the broken
-- match, so fixing the code changed nothing until that cache was cleared. Any resolution fix must
-- invalidate what the old behaviour poisoned." The venue rows were the fix; this is the
-- invalidation that was missing from it.
--
-- SCOPED TO THE AFFECTED COUNTRIES, not a blanket clear. `figi_missing_at` is earned honestly
-- almost everywhere else — a security whose ISIN OpenFIGI genuinely cannot map — and clearing it
-- globally would re-ask a rate-limited provider for thousands of answers we already hold. Only
-- securities in the five countries whose venues did not exist until migration 63 had their answer
-- changed by it.
--
-- BOTH ISIN-KEYED FLAGS, because both were set under the old catalogue.
-- `market.symbol_cache_classification` records that neither is cleared by a corrected SYMBOL —
-- correctly, since they are keyed on the ISIN. A new VENUE is the different event that does
-- invalidate them, and that is exactly why this cannot be left to `clear_symbol_caches`.
--
-- ONE-SHOT: it undoes a specific past state. Re-running it every deploy would clear marks earned
-- honestly after this point and re-ask OpenFIGI for them four times a day.

do $$
declare
  cleared bigint;
begin
  if exists (select 1 from market.one_shot where key = '64-clear-marks-for-newly-swept-venues') then
    return;
  end if;

  update market.security s
     set figi_missing_at         = null,
         local_symbol_missing_at = null
   where s.country_iso2 in ('KW', 'QA', 'VN', 'AR')
     and (s.figi_missing_at is not null or s.local_symbol_missing_at is not null);

  get diagnostics cleared = row_count;

  insert into market.one_shot (key, reason) values
    ('64-clear-marks-for-newly-swept-venues',
     format('Cleared figi/local_symbol marks on %s securities in KW, QA, VN and AR. They were '
            || 'recorded unresolvable because OpenFIGI returned listings on KK/QD/VN/VM/AR, none '
            || 'of which was a venue market.exchange knew until migration 63 added them.', cleared));
end $$;

notify pgrst, 'reload schema';
