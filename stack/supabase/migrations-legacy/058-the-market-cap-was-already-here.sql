-- 2,871 MARKET CAPS WERE ALREADY IN THE DATABASE, IN A JSONB COLUMN, UNREAD.
--
-- `security.market_cap` is filled by `security-profiles` from `equity/profile`, which does not
-- carry a cap for most non-US listings. So coverage sat at **8,163 of 12,348 equities (66%)**,
-- with `market_cap_at` unset for the remainder — no attempt ever recorded, which is why it read as
-- "the provider does not have this" rather than as a gap.
--
-- It is not a gap. Measured 2026-08-14: of the 2,952 equities that have a sector (so the profile
-- DID answer) and no market cap, **2,871 already had one in `security_fundamentals.raw.market_cap`**
-- — fetched by `security-fundamentals`, stored in the raw payload, and never promoted to the
-- column the app reads. COSCO Shipping ¥234bn, HEXPOL, Emmi, Jinxin Fertility, Trina Solar.
--
-- This is the FOURTH time the answer was already inside a response we were fetching: market cap
-- from the profile, the operating country from the profile (migration 56), the currency from these
-- same metrics, and now the cap from these same metrics. The rule that keeps being relearned is
-- to look at what a response CONTAINS before concluding a field needs a new provider or a paid key.
--
-- The resource now writes it going forward; this promotes what is already held.
--
-- ONE-SHOT even though it only fills NULLs, because "only fills nulls" is not the same as "safe to
-- re-run for ever": `security-fundamentals` refreshes `raw` on its own cadence, and a migration
-- that re-promotes on every deploy would silently outrank the resource's own newer write whenever
-- the column had been cleared or corrected by hand. The forward path belongs to the resource.
--
-- CURRENCY. Like every other market cap here, this is denominated in the security's OWN currency —
-- COSCO's 234,915,282,944 is CNY. That is why `market-verify`'s mega-cap check is US-only and has
-- to stay so, and why the companion check added the same day compares by FUND WEIGHT instead.

do $$
declare
  promoted bigint;
begin
  if exists (select 1 from market.one_shot where key = '58-promote-market-cap-from-fundamentals') then
    return;
  end if;

  update market.security s
     set market_cap    = (f.raw ->> 'market_cap')::numeric,
         market_cap_at = coalesce(f.as_of, now())
    from market.security_fundamentals f
   where f.security_id = s.security_id
     and s.market_cap is null
     and f.raw ? 'market_cap'
     and jsonb_typeof(f.raw -> 'market_cap') = 'number'
     and (f.raw ->> 'market_cap')::numeric > 0;

  get diagnostics promoted = row_count;

  insert into market.one_shot (key, reason) values
    ('58-promote-market-cap-from-fundamentals',
     format('Promoted %s market caps from security_fundamentals.raw into security.market_cap. '
            || 'equity/profile carries no cap for most non-US listings, so coverage was 8,163 of '
            || '12,348 (66%%) while the values sat unread in the metrics payload.', promoted));
end $$;

notify pgrst, 'reload schema';
