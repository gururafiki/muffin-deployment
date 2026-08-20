-- Prices for the whole universe, keyed on the SECURITY — IDEMPOTENT.
--
-- `market.prices.symbol` is `references market.instruments (symbol)`, so that table is structurally
-- scoped to the curated 47 — which is exactly why it holds 4,967 rows and no more. Migration 41
-- added a universe-wide price resource that wrote into it and the foreign key refused, correctly:
--
--   prices upsert failed: insert or update on table "prices" violates foreign key constraint
--   "prices_symbol_fkey"
--
-- The constraint was right and the design was wrong. Fixed by keying on `security_id` rather than
-- widening `prices`, for a reason today made concrete: **a symbol is not a stable key**. Migration
-- 39 changed the display symbol for 41% of non-US securities (HXGBF -> HEXA-B.ST), and every row
-- keyed on the old one had to be re-keyed by hand. A price series keyed on `security_id` would have
-- needed no migration at all, and will not need one the next time a listing changes.
--
-- `market.prices` is LEFT ALONE. It serves the curated instruments, including the ones that are not
-- securities at all (USD, US10Y, GLD, BTC) and therefore can never have a `security_id`.

create table if not exists market.security_price (
  security_id uuid    not null references market.security (security_id) on delete cascade,
  date        date    not null,
  close       numeric not null,
  primary key (security_id, date)
);

create index if not exists security_price_date_idx on market.security_price (security_id, date desc);

comment on table market.security_price is
  'Daily closes for the fund-derived universe, keyed on the security so a listing or symbol change cannot orphan the series. ~400-day rolling window, pruned on write. market.prices remains the curated-instrument series, including instruments that are not securities.';

-- ── the backlog now measures the right table ────────────────────────────────
drop view if exists market.pending_prices;
create view market.pending_prices as
select
  s.security_id,
  sym.symbol,
  coalesce(ps.symbol, sym.symbol)  as fetch_symbol,
  p.last_date,
  coalesce(max(h.weight), 0)       as best_weight
from market.security s
join market.security_symbol sym on sym.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join lateral (
  select max(sp.date) as last_date from market.security_price sp where sp.security_id = s.security_id
) p on true
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and (p.last_date is null or p.last_date < (now() at time zone 'utc')::date - 2)
  and (s.prices_missing_at is null or s.prices_missing_at < now() - interval '30 days')
group by s.security_id, sym.symbol, ps.symbol, p.last_date
order by best_weight desc;

-- ── one series for the app to read ──────────────────────────────────────────
-- The chart asks by SYMBOL and should not care which table a security's history lives in. A curated
-- instrument that is linked to a security can appear in both, so the security series wins: it is
-- refreshed incrementally by `security-prices`, while `market.prices` is rewritten only when the
-- 47-row curated resource runs.
drop view if exists market.price_series;
create view market.price_series as
select distinct on (symbol, date) symbol, date, close
from (
  select sym.symbol, sp.date, sp.close, 1 as priority
  from market.security_price sp
  join market.security_symbol sym on sym.security_id = sp.security_id
  union all
  select p.symbol, p.date, p.close, 2 as priority
  from market.prices p
) x
order by symbol, date, priority;

comment on view market.price_series is
  'Every daily close the app can chart, by symbol: the security series first, the curated instrument series second. `distinct on` picks per (symbol, date) so a linked instrument present in both is not drawn twice.';

grant select on market.price_series to anon, authenticated, service_role;
grant select on market.pending_prices to service_role;

notify pgrst, 'reload schema';
