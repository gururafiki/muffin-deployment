-- Liquidated funds, and the countries that depended on them — IDEMPOTENT.
--
-- Four tracked funds have never ingested, and the reason is not a bug: they no longer exist. Their
-- last SEC filing, from EDGAR full-text search 2026-08-13:
--
--   EGPT  VanEck Egypt              last NPORT-P 2022-11-28
--   NGE   Global X MSCI Nigeria     last NPORT-P 2023-12-29
--   PGAL  Global X MSCI Portugal    last NPORT-P 2024-04-01
--   GXG   Global X MSCI Colombia    last NPORT-P 2025-02-27  -- but STILL TRADING, see below
--
-- The ingest reported "not an SEC-registered fund (no N-PORT to read)", which is a conclusion drawn
-- from a lookup miss in `company_tickers_mf.json` — SEC drops delisted funds from that file. The
-- conclusion happened to be right; the reasoning was not, and it failed the resource on every run.
--
-- WHAT THIS BREAKS IF LEFT ALONE. `countries.drillable` is derived from `etf_symbol`, so Egypt,
-- Nigeria and Portugal were openable pages priced off a dead ETF. yfinance keeps serving a delisted
-- fund's final bars, so every period was measured between two identical closes and rendered as
-- **+0.0%** — which reads as "the market was flat", not "this fund is dead". Measured 2026-08-13:
-- PT, EG and NG each showed +0.0% across all nine periods, dated that day.
--
-- The general fix is in `returnsFor`, which now refuses to report any series whose last bar is more
-- than ten days old — that protects every instrument, not these four. This migration removes the
-- rows already stored and stops the funds being retried.
--
-- COLOMBIA IS DIFFERENT AND STAYS. GXG still trades (a bar on 2026-08-12) and its +42.5% is real;
-- only its N-PORT filings stopped. So it keeps its country page and its prices, and loses only the
-- holdings refresh. That distinction is why the staleness rule keys on the DATA rather than on a
-- list of tickers.

alter table market.tracked_fund add column if not exists retired_at timestamptz;
comment on column market.tracked_fund.retired_at is
  'When this fund was found to have stopped filing N-PORT. Set instead of deleting, so the holdings it contributed keep their provenance and the row documents why it is no longer refreshed.';

update market.tracked_fund
   set enabled = false,
       retired_at = coalesce(retired_at, now()),
       notes = coalesce(notes, '') ||
         case symbol
           when 'EGPT' then 'Liquidated; last N-PORT 2022-11-28. No bars at the price provider.'
           when 'NGE'  then 'Liquidated; last N-PORT 2023-12-29. No bars at the price provider.'
           when 'PGAL' then 'Liquidated; last N-PORT 2024-04-01. No bars at the price provider.'
           else ''
         end
 where symbol in ('EGPT', 'NGE', 'PGAL')
   and (enabled or retired_at is null);

-- GXG keeps `enabled = false` for HOLDINGS (it stopped filing) but its country page and prices are
-- real, so `countries.etf_symbol` is deliberately left pointing at it.
update market.tracked_fund
   set enabled = false,
       retired_at = coalesce(retired_at, now()),
       notes = coalesce(notes, '') || 'Stopped filing N-PORT after 2025-02-27 but STILL TRADES; country prices remain valid, holdings do not refresh.'
 where symbol = 'GXG'
   and (enabled or retired_at is null);

-- Those three countries lose their page: there is no fund to price them, and a page with no number
-- is worse than no page. Czechia and Hungary are already in this state for the same reason.
update market.countries set etf_symbol = null where iso2 in ('EG', 'NG', 'PT');
update market.countries
   set drillable = (etf_symbol is not null)
 where drillable is distinct from (etf_symbol is not null);

-- The +0.0% rows already stored. `returnsFor` will not write them again, but it also will not
-- produce anything for these scopes, so nothing would overwrite them.
delete from market.performance
 where scope = 'country' and scope_id in ('EG', 'NG', 'PT');
delete from market.performance
 where scope = 'instrument' and scope_id in ('EGPT', 'NGE', 'PGAL');
