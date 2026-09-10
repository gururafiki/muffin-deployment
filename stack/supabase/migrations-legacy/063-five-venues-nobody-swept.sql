-- FOUR DRILLABLE COUNTRIES HAD NO VENUE IN THE SWEEP AT ALL, so their exchanges could never be
-- enumerated and their securities could never resolve a symbol.
--
-- Measured 2026-08-14, after `exchange-listings` was finally put on the cron: the catalog's 54
-- venues cover 42 countries, and the app offers a country page for 45. The three missing ones that
-- already hold securities are the tell —
--
--   Kuwait   40 equities tracked, every one with NO symbol
--   Qatar    35 equities tracked, every one with NO symbol
--   Vietnam  57 equities tracked, every one with NO symbol
--
-- — because a symbol is resolved against a venue this pipeline sweeps, and nothing swept theirs.
-- Argentina had no securities at all, which is why it showed up as a page with nothing behind it.
--
-- EVERY CODE AND SUFFIX HERE IS DERIVED FROM A PUBLISHED SOURCE, not recalled. That is the Taiwan
-- rule: `exchanges.ts` was written from memory of Bloomberg codes, spot-checked against four
-- securities that all happened to agree, and silently dropped 534 Taiwanese securities.
--
--   1. exchCode came from OpenFIGI `/v3/mapping` on an ISIN we already hold for that country —
--      KW0EQ0200281 -> KK, QA0007227695 -> QD, VN000000KDC3 -> VN and VM.
--   2. The suffix came from Yahoo's own search, the same endpoint `security-yahoo-symbols` uses,
--      on the ticker OpenFIGI returned: NINV -> `NINV.KW`, QNNS -> `QNNS.QA`, KDC -> `KDC.VN`,
--      DRH -> `DRH.VN` (Hanoi, checked separately rather than assumed to match Ho Chi Minh).
--   3. Argentina has no ISIN to start from, so it went the other way: `/v3/filter` on `AR` returns
--      213 common stocks with unmistakably Argentine names (Central Puerto, Distribuidora de Gas
--      Cuyana, Enel Generación Costanera), and Yahoo gives those `CEPU.BA` and `DGCU2.BA`.
--
-- THE CODE IS NOT THE SUFFIX and this is exactly where that bites: Doha is `QD` to OpenFIGI and
-- `.QA` to Yahoo, Kuwait `KK` and `.KW`, Buenos Aires `AR` and `.BA`. Two of the three would be
-- wrong if either were inferred from the other, and a wrong suffix does not error — it produces a
-- symbol the price provider answers nothing for, which this pipeline then negative-caches.
--
-- Totals from `/v3/filter`, so the size is measured rather than hoped: VN 1,617 · VM 409 · AR 213 ·
-- KK 145 · QD 56 — about 2,440 listings, of which the ~132 already-tracked securities are the part
-- that stops being symbol-less.
--
-- `preference` follows the existing convention: the larger venue of a two-venue country is 1.

insert into market.exchange (exch_code, country_iso2, suffix, preference) values
  ('VN', 'VN', '.VN', 1),   -- Ho Chi Minh
  ('VM', 'VN', '.VN', 2),   -- Hanoi
  ('KK', 'KW', '.KW', 1),   -- Kuwait
  ('QD', 'QA', '.QA', 1),   -- Doha
  ('AR', 'AR', '.BA', 1)    -- Buenos Aires
on conflict (exch_code) do update set
  country_iso2 = excluded.country_iso2,
  suffix       = excluded.suffix,
  preference   = excluded.preference;

-- Same sync as migration 37: the catalog is the source, the cursor carries the sweep's own state.
insert into market.exchange_cursor (exch_code, country_iso2, suffix)
select e.exch_code, e.country_iso2, e.suffix
from market.exchange e
where e.enabled
on conflict (exch_code) do update set
  country_iso2 = excluded.country_iso2,
  suffix       = excluded.suffix;

notify pgrst, 'reload schema';
