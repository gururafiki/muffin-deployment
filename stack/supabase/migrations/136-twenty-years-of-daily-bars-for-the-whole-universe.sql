-- TWENTY-PLUS YEARS OF DAILY BARS, FOR THE WHOLE UNIVERSE — NOT JUST THE US.
--
-- `security_price` already spans 20 years, but the deep half of it is WEEKLY: `security-prices`
-- keeps a ~400-day daily window and `security-price-history` fills 2006->now at `interval=1W`.
-- So a 20-year chart is drawable and a 20-year BACKTEST is not — intra-week movement simply is
-- not stored. `PRICE_HISTORY_YEARS` is already 20; the missing thing is resolution, not span.
--
-- ── MEASURED BEFORE BUILDING, AND ON THE SYMBOLS EXPECTED TO BE WORST ─────────────────────────
--
-- The obvious risk was that deep daily history is a US privilege, the way quarterly statements
-- turned out to be (migration 106) and EPS history still is. It is not. Driven 2026-08-28 against
-- the deployed openbb-api, asking for `start_date=1970-01-01` so the provider returns everything
-- it has:
--
--     BHP.AX      9,893 bars from 1988-01-29      SAP.DE      7,264 from 1998-04-09
--     NESN.SW     9,373 bars from 1990-01-03      7203.T      6,824 from 1999-05-06
--     RELIANCE.NS 7,696 bars from 1996-01-01      005930.KS   6,663 from 2000-01-04
--     2330.TW     6,628 bars from 2000-01-04      PETR4.SA    6,691 from 2000-01-03
--     MRP.JO      6,821 bars from 2000-01-04      0700.HK     5,482 from 2004-06-16
--
-- Every one clears twenty years. Tencent's shorter series is its 2004 IPO — the company's age, not
-- a gap in the data. Average ~7,300 bars is ~29 years, so this is "20+" comfortably.
--
-- ── WHY THE WEEKLY SERIES STAYS ───────────────────────────────────────────────────────────────
--
-- It would be natural to retire weekly once daily covers the same span. That would break the
-- charts. A 20-year window is ~5,040 daily points per symbol against ~1,040 weekly, and
-- `price_series` has already crossed the anon 3-second timeout TWICE (migrations 094/096, then
-- 102). The two grains overlap ON PURPOSE: weekly is the long-range rendering path, daily is the
-- resolution. This migration deepens daily and touches weekly not at all.
--
-- ── COST, MEASURED ────────────────────────────────────────────────────────────────────────────
--
-- One 12-symbol batch at full history is 11.6 MB and 8.1 s (against 188 KB for one symbol of
-- weekly). The binding limit is therefore MEMORY, not the 90-second budget: the worker has 256 MB
-- and `security-xbrl` has been killed by the supervisor at comparable pressure, so the resource
-- takes a handful of batches per run rather than filling the clock. ~50M daily rows at the
-- measured 333 bytes/row all-in is ~17 GB, against 85 GB free on the block volume.

-- ── THE "DONE" MARKER ─────────────────────────────────────────────────────────────────────────
--
-- A COLUMN, NOT A `min(date)` ANTI-JOIN. Every security already HAS daily rows — the 400-day
-- window — so "has no daily bars" cannot express "has no DEEP daily bars", and computing
-- `min(date) group by security_id` over 11M rows (soon 50M+) on every backlog read is exactly the
-- whole-table scan `derived_at` was added to `security_statement` to avoid. `daily_history_from`
-- records the earliest bar the deep pass actually obtained, so it also answers "how far back does
-- this security go" without a scan.
alter table market.security add column if not exists daily_history_from date;
comment on column market.security.daily_history_from is
  'Earliest DAILY bar obtained by security-daily-history. Null means the deep backfill has not run for this security. Not derived from security_price on read: that is a whole-table scan on every backlog evaluation.';

-- The negative cache. 30 days, never "never": a security the provider has no deep history for
-- today may be carried later, and a security whose symbol gets corrected must be re-asked (which
-- is what putting it in `clear_symbol_caches` below does).
alter table market.security add column if not exists daily_history_missing_at timestamptz;
comment on column market.security.daily_history_missing_at is
  'We asked for deep daily history for this symbol and the provider returned nothing. 30-day negative cache.';

-- ── THE BACKLOG ───────────────────────────────────────────────────────────────────────────────
--
-- BY FUND WEIGHT, ACROSS THE WHOLE UNIVERSE. This is a one-off backfill of ~11,700 securities
-- against a rate-limited provider, so the ORDER is what decides what a month of budget buys. Fund
-- weight rather than market cap, for the reason the mega-cap canary already exists: a percentage
-- is free of currency, cap and country, while 34% of the universe has no market cap at all and
-- `market_cap` is denominated in each security's own currency.
--
-- The fetch key is `coalesce(provider_symbol, ticker)` and that is load-bearing for a non-US
-- universe: `security_identifier.ticker` is OpenFIGI's US lookup, which for a foreign company is a
-- thin OTC foreign-ordinary line (SAPGF, not SAP.DE). Migration 039 measured 365 of 900 sampled
-- non-US securities displaying that way while being priced off the local symbol.
drop view if exists market.pending_daily_history;
create view market.pending_daily_history as
select
  s.security_id,
  sym.symbol,
  coalesce(ps.symbol, sym.symbol) as fetch_symbol,
  coalesce(max(h.weight), 0)      as best_weight
from market.security s
join market.security_symbol sym on sym.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and s.daily_history_from is null
  and (s.daily_history_missing_at is null
       or s.daily_history_missing_at < now() - interval '30 days')
group by s.security_id, sym.symbol, coalesce(ps.symbol, sym.symbol)
order by best_weight desc, s.security_id;

comment on view market.pending_daily_history is
  'Equities with no deep DAILY history yet, heaviest fund holding first. Whole universe, not US-only: measured 2026-08-28, every non-US venue tried returns 20+ years of daily bars.';

grant select on market.pending_daily_history to service_role;

-- ── THE TWO CONTRACTS A NEW NEGATIVE CACHE MUST JOIN ──────────────────────────────────────────
--
-- `tests/negative-caches-are-classified.sql` fails CI on any `%_missing_at` column nobody
-- classified, and `clear_symbol_caches` is what a corrected symbol calls. `prices_missing_at`
-- arrived as migration 42 and never joined the clear list, which locked 4,801 of 12,348 equities
-- out of `pending_prices` with no error and `ok: true` throughout. Both lists, in one migration.
--
-- COPIED FROM MIGRATION 106, NOT 050. `create or replace view` means the last file wins outright,
-- and rebuilding this list from the migration that INTRODUCED it is how 106 silently deleted the
-- eight entries added by 059/067/087/088/094/095/097.
drop view if exists market.symbol_cache_classification;
create view market.symbol_cache_classification as
select * from (values
  ('industry_missing_at',          true,  'yfinance profile fetched by symbol'),
  ('profile_missing_at',           true,  'yfinance profile fetched by symbol'),
  ('performance_missing_at',       true,  'historical bars fetched by symbol'),
  ('fundamentals_missing_at',      true,  'metrics fetched by symbol'),
  ('statements_missing_at',        true,  'statements fetched by symbol'),
  ('prices_missing_at',            true,  'daily bars fetched by symbol'),
  ('quarters_missing_at',          true,  'quarterly statements fetched by the PRICED symbol'),
  ('provider_country_missing_at',  true,  'yfinance profile fetched by symbol'),
  ('corporate_actions_missing_at', true,  'Tiingo EOD fetched by the US ticker'),
  ('dividends_missing_at',         true,  'yfinance dividends fetched by the PRICED symbol'),
  ('price_history_missing_at',     true,  'weekly history fetched by the PRICED symbol'),
  ('daily_history_missing_at',     true,  'deep daily history fetched by the PRICED symbol'),
  ('share_stats_missing_at',       true,  'share statistics fetched by the PRICED symbol'),
  ('estimates_missing_at',         true,  'analyst consensus fetched by the PRICED symbol'),
  ('profile_detail_missing_at',    true,  'yfinance profile fetched by symbol'),
  ('figi_missing_at',              false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at',      false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at',      false, 'the resolver''s own flag — clearing it here would loop'),
  ('statement_currency_missing_at', false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'),
  ('xbrl_missing_at',              false, 'company facts are asked for by CIK; a new provider symbol says nothing about the filer')
) as t(column_name, symbol_keyed, reason);

comment on view market.symbol_cache_classification is
  'Which negative caches a new symbol invalidates, and why. Enforced by tests/negative-caches-are-classified.sql: a `%_missing_at` column missing from here fails CI.';

grant select on market.symbol_cache_classification to service_role;

-- Symbol-keyed, so a corrected symbol must re-ask. Note this is drop-then-create: `create or
-- replace function` PRESERVES the existing ACL, so a re-run migration can only ever ADD a
-- privilege — which is why every function here is dropped first.
drop function if exists market.clear_symbol_caches(uuid);
create function market.clear_symbol_caches(p_security_id uuid)
returns void language sql as $$
  update market.security set
    industry_missing_at         = null,
    profile_missing_at          = null,
    performance_missing_at      = null,
    fundamentals_missing_at     = null,
    statements_missing_at       = null,
    prices_missing_at           = null,
    quarters_missing_at         = null,
    provider_country_missing_at = null,
    corporate_actions_missing_at = null,
    dividends_missing_at        = null,
    price_history_missing_at    = null,
    daily_history_missing_at    = null,
    share_stats_missing_at      = null,
    estimates_missing_at        = null,
    profile_detail_missing_at   = null
  where security_id = p_security_id;
$$;

revoke all on function market.clear_symbol_caches(uuid) from public;
grant execute on function market.clear_symbol_caches(uuid) to service_role;

-- ── THE ROTATION ──────────────────────────────────────────────────────────────────────────────
--
-- Registered here because `market.cron_resource` is the source of truth for what runs, and
-- `logic-check.ts` fails on a resource that exists in the function and is never scheduled —
-- `exchange-listings` sat in exactly that state for weeks. Positioned beside the weekly history
-- resource it complements.
insert into market.cron_resource (position, resource) values
  (325, 'security-daily-history')
on conflict (position) do update set resource = excluded.resource;

notify pgrst, 'reload schema';
