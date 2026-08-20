-- TWENTY YEARS OF PRICES, AND THE PRUNE THAT WOULD HAVE DELETED THEM.
--
-- `security_price` holds a ~400-day rolling window: 3,056,435 rows over 11,347 securities, 568 MB,
-- 2025-07-09 .. 2026-08-20. financecharts offers 1M · 3M · 6M · YTD · 1Y · 3Y · 5Y · 10Y · 15Y ·
-- 20Y, and computes a P/E per day from a daily close and a stepwise quarterly EPS. Neither the
-- long ranges nor a ratio series is possible against 400 days.
--
-- ── THE PRUNE IS THE DANGEROUS PART, NOT THE FETCH ──────────────────────────────────────────
--
-- `security-prices` ends every run with
--
--   delete from security_price where security_id in (...) and date < <400 days ago>
--
-- which is correct for a rolling window and would silently destroy a 20-year backfill the first
-- time it touched a security. No error, no count, nothing in `refresh_log` — the history would
-- simply be gone and the chart would shorten back to 400 days. The prune is now GRAIN-AWARE, and
-- `an-old-bar-is-not-stale.sql` proves it by deleting the qualifier and watching weekly history
-- disappear.
--
-- ── WHY `grain` IS IN THE PRIMARY KEY ───────────────────────────────────────────────────────
--
-- The weekly series covers the WHOLE twenty years, including the two the daily series covers. That
-- is deliberate: a weekly series that stopped two years ago would make a 20Y chart end in 2024.
-- So one date legitimately carries a weekly bar AND a daily bar, and `(security_id, date)` cannot
-- hold both — the second would overwrite the first and flip its grain.
--
-- The overlap costs ~104 rows per security and buys a complete series at either resolution, each
-- answerable in ONE query with no stitching.
--
-- ── THE ROW BUDGET, MEASURED RATHER THAN ESTIMATED ──────────────────────────────────────────
--
-- Measured against the deployed openbb-api: `interval=1W&start_date=2006-01-01` returns **1,077**
-- weekly bars, and it works for every market tried — AAPL, SAP.DE, 7203.T, 005930.KS all return
-- 1,077 — and it batches (three symbols returned 3,231). 20 years daily is 5,190 bars, which is
-- why the daily series stays a window.
--
--   weekly 20y   1,077  +  daily 2y  ~504   =  ~1,581 rows per security
--   x 11,347 securities                     =  ~17.9M rows
--   at 186 bytes/row (measured: 568 MB / 3,056,435)  =  ~3.3 GB
--
-- The node had 14 GB free when this was written. That is a real cost against a real budget, which
-- is why `PRICE_HISTORY_YEARS` is a constant in one place rather than a number scattered through
-- the fetch.
--
-- A 20-year weekly series is 1,077 rows, which is ABOVE `PGRST_DB_MAX_ROWS` (1,000). PostgREST
-- does not error on that — it returns a shorter answer — so any reader must page explicitly. The
-- app is changed in the same breath; see muffin-ui.

do $$ begin
  alter table market.security_price add column grain text not null default 'daily';
exception when duplicate_column then null; end $$;

do $$ begin
  alter table market.security_price
    add constraint security_price_grain_chk check (grain in ('daily', 'weekly'));
exception when duplicate_object then null; end $$;

comment on column market.security_price.grain is
  'How the bar was sampled. `daily` is a rolling window; `weekly` is the full 20-year history and DELIBERATELY overlaps it, so a long chart does not end where the daily window begins. Part of the primary key, because one date carries both.';

-- ── the key ──────────────────────────────────────────────────────────────────────────────────
-- Guarded on the CURRENT key rather than blind, because migrations re-run: on pass 2 the primary
-- key is already the three-column one and dropping it to re-add the same thing would churn a
-- multi-million-row index on every deploy.
do $$
declare cols text;
begin
  select string_agg(a.attname, ',' order by array_position(i.indkey::smallint[], a.attnum))
    into cols
    from pg_index i
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = 'market.security_price'::regclass and i.indisprimary;

  if cols is distinct from 'security_id,grain,date' then
    alter table market.security_price drop constraint if exists security_price_pkey;
    alter table market.security_price add primary key (security_id, grain, date);
  end if;
end $$;

-- Serves both the chart's (security, grain, range) read and the prune's (security, grain, cutoff)
-- delete. The old `security_price_date_idx` leads on security_id and date, so it cannot answer a
-- grain-qualified range without a filter step.
create index if not exists security_price_grain_date_idx
  on market.security_price (security_id, grain, date desc);

-- ── the negative cache ───────────────────────────────────────────────────────────────────────
-- SYMBOL-KEYED: the history is fetched with the provider symbol, so a corrected symbol must clear
-- it — unlike `figi_missing_at`, which is keyed on the ISIN and must not be.
alter table market.security
  add column if not exists price_history_missing_at timestamptz;

comment on column market.security.price_history_missing_at is
  'We asked for this security''s long weekly history and the provider had none. Symbol-keyed, so market.clear_symbol_caches must clear it — a corrected symbol is a different question.';

create or replace function market.clear_symbol_caches(p_security_id uuid)
returns void language sql as $$
  update market.security set
    industry_missing_at         = null,
    profile_missing_at          = null,
    performance_missing_at      = null,
    fundamentals_missing_at     = null,
    statements_missing_at       = null,
    prices_missing_at           = null,
    provider_country_missing_at = null,
    corporate_actions_missing_at = null,
    dividends_missing_at        = null,
    price_history_missing_at    = null
  where security_id = p_security_id;
$$;

drop view if exists market.symbol_cache_classification;
create view market.symbol_cache_classification as
select * from (values
  ('industry_missing_at',          true,  'yfinance profile fetched by symbol'),
  ('profile_missing_at',           true,  'yfinance profile fetched by symbol'),
  ('performance_missing_at',       true,  'historical bars fetched by symbol'),
  ('fundamentals_missing_at',      true,  'metrics fetched by symbol'),
  ('statements_missing_at',        true,  'statements fetched by symbol'),
  ('prices_missing_at',            true,  'daily bars fetched by symbol'),
  ('provider_country_missing_at',  true,  'yfinance profile fetched by symbol'),
  ('corporate_actions_missing_at', true,  'Tiingo EOD fetched by the US ticker'),
  ('dividends_missing_at',         true,  'yfinance dividends fetched by the PRICED symbol'),
  ('price_history_missing_at',     true,  'weekly history fetched by the PRICED symbol'),
  ('figi_missing_at',              false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at',      false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at',      false, 'the resolver''s own flag — clearing it here would loop'),
  ('statement_currency_missing_at', false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files')
) as t(column_name, symbol_keyed, reason);

grant select on market.symbol_cache_classification to service_role;

-- ── the backlog ──────────────────────────────────────────────────────────────────────────────
-- Anti-join on the FIRST left-joined relation, the shape every draining backlog here has:
-- "has a symbol, has no weekly bar". A security whose provider has no long history is excluded by
-- the negative cache rather than re-asked for ever.
drop view if exists market.pending_price_history;

create view market.pending_price_history as
select
  s.security_id,
  sym.symbol,
  coalesce(ps.symbol, sym.symbol) as fetch_symbol,
  coalesce(max(h.weight), 0)      as best_weight
from market.security s
join market.security_symbol sym on sym.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_price w
  on w.security_id = s.security_id and w.grain = 'weekly'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and w.security_id is null
  and (s.price_history_missing_at is null
       or s.price_history_missing_at < now() - interval '30 days')
group by s.security_id, sym.symbol, coalesce(ps.symbol, sym.symbol)
-- BY WEIGHT. This is a one-off backfill of ~11,347 securities against a rate-limited provider, so
-- the ORDER decides what a month of budget buys: the securities people actually open, first.
order by best_weight desc, s.security_id;

comment on view market.pending_price_history is
  'Equities with no weekly history yet, heaviest fund holding first. A one-off backfill against a rate-limited provider, so the order is the feature.';

grant select on market.pending_price_history to service_role;

-- ── the serving view gains the grain ─────────────────────────────────────────────────────────
-- The app must be able to ask for one resolution: a 20-year weekly series is 1,077 rows and a
-- 20-year daily one is 5,190, and mixing them in a single answer would hand the chart two bars for
-- the same day.
drop view if exists market.price_series;

create view market.price_series as
select distinct on (symbol, grain, date) symbol, date, close, grain
from (
  select sym.symbol, sp.date, sp.close, sp.grain, 1 as priority
  from market.security_price sp
  join market.security_symbol sym on sym.security_id = sp.security_id
  union all
  select p.symbol, p.date, p.close, 'daily'::text as grain, 2 as priority
  from market.prices p
) x
order by symbol, grain, date, priority;

comment on view market.price_series is
  'Every close the app can chart, by symbol and GRAIN: the security series first, the curated instrument series second. A reader must filter on `grain` — the two overlap by design, and a 20-year weekly series is 1,077 rows, above PGRST_DB_MAX_ROWS, so it must also page.';

grant select on market.price_series to anon, authenticated, service_role;

notify pgrst, 'reload schema';
