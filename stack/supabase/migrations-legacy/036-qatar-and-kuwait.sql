-- Give Qatar and Kuwait a page — IDEMPOTENT.
--
-- Measured 2026-08-12 against MSCI's tier lens: of 24 emerging-market members, four had no country
-- page — CZ, HU, QA, KW. A country is openable exactly when it has an ETF to price it (migration 19
-- made `drillable` derived rather than hand-maintained), so the gap is a missing fund, not a
-- missing flag.
--
-- Two of the four have one, confirmed against the provider rather than assumed:
--   QAT  iShares MSCI Qatar ETF    USD
--   KWT  iShares MSCI Kuwait ETF   USD
--
-- CZECHIA AND HUNGARY DELIBERATELY STAY WITHOUT PAGES. No liquid single-country ETF exists for
-- either, so there is nothing to derive a price series from — a structural limit, not a backlog
-- item. The same is true of 19 of MSCI's 21 frontier markets. Inventing a proxy (a regional fund,
-- or the nearest neighbour) would put a number under a country's name that is not that country's.
--
-- WHY THIS IS A MIGRATION AND NOT A STUDIO ROW. `tracked_fund` is genuinely the editable control
-- surface — migration 11 seeds it `on conflict do nothing` precisely so hand-added funds survive.
-- But `market.countries` is re-seeded by migration 04 with `on conflict DO UPDATE` on `etf_symbol`
-- and `drillable`, so a Studio edit there is silently reverted on the next deploy. The fund half
-- could have been a row; the country half could not.

insert into market.tracked_fund (symbol, name, kind, represents_code) values
  ('QAT', 'iShares MSCI Qatar',  'country', 'QA'),
  ('KWT', 'iShares MSCI Kuwait', 'country', 'KW')
on conflict (symbol) do nothing;

-- `cik`, `series_id` and `last_accession` are left null on purpose: the ingest discovers them via
-- EDGAR full-text search on the first run. Seeding a CIK by hand is how a fund ends up pointing at
-- the wrong series — the trust files one N-PORT per series per quarter, and iShares' CIK carries
-- 1,433 filings.

update market.countries set etf_symbol = 'QAT' where iso2 = 'QA' and etf_symbol is distinct from 'QAT';
update market.countries set etf_symbol = 'KWT' where iso2 = 'KW' and etf_symbol is distinct from 'KWT';

-- Re-apply migration 19's rule. It runs BEFORE this file, so the two rows above would otherwise
-- carry an ETF and stay unopenable until the following deploy. Stated as the same derivation rather
-- than setting `drillable = true` directly, so there is one definition of what makes a country
-- openable and it cannot drift.
update market.countries
   set drillable = (etf_symbol is not null)
 where drillable is distinct from (etf_symbol is not null);

notify pgrst, 'reload schema';
