-- Keep the price history we already download — IDEMPOTENT.
--
-- `security-performance` fetches ~400 days of daily bars for a security, computes seven return
-- numbers, and throws the series away. `market.prices` holds 4,967 rows: the curated instruments
-- only. So a chart is possible for 47 securities out of 10,060, and every return is recomputed by
-- re-downloading history we have already paid for.
--
-- FETCHED INCREMENTALLY, from the newest bar we hold rather than from a fixed window. That is the
-- whole point: a daily refresh should ask for one day, not four hundred.
--
-- STORED DAILY, NOT DOWNSAMPLED. The existing `instrument-prices` resource downsamples (daily
-- inside 90 days, weekly before), which is right for a table written whole each time and WRONG for
-- one appended to: a bar that was daily when written never becomes weekly as it ages, so the two
-- rules fight and the series grows lumpy. The chart offers 1M/3M/6M/1Y — 365 days is the longest
-- thing it can draw — so a 400-day daily window needs no downsampling to serve it, and the row
-- count per security is bounded at ~400 instead of growing forever.
--
-- Sizing, measured before choosing: ~10,000 securities x 400 bars is ~4M rows, roughly 450 MB with
-- indexes, against 18 GB free on the node. Checkpoint growth is the pressure here, not market data.

alter table market.security add column if not exists prices_missing_at timestamptz;
comment on column market.security.prices_missing_at is
  'When the price provider last returned no series for this security. Excludes it from pending_prices for 30 days — the same negative cache every other backlog needs, and for the same reason.';

create index if not exists security_prices_missing_idx on market.security (prices_missing_at);
-- The incremental read is "newest bar for this symbol", which is this index used backwards.
create index if not exists prices_symbol_date_idx on market.prices (symbol, date desc);

-- ── the backlog ─────────────────────────────────────────────────────────────
-- `last_date` is what makes the fetch incremental: the resource asks the provider for bars AFTER
-- this, not for a fixed window. A security with none gets the full window exactly once.
drop view if exists market.pending_prices;
create view market.pending_prices as
select
  s.security_id,
  sym.symbol,
  coalesce(ps.symbol, sym.symbol)          as fetch_symbol,
  p.last_date,
  coalesce(max(h.weight), 0)               as best_weight
from market.security s
join market.security_symbol sym on sym.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join lateral (
  select max(pr.date) as last_date from market.prices pr where pr.symbol = sym.symbol
) p on true
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  -- Nothing stored, or the newest bar is not from the last trading day or two. Two days rather
  -- than one so a weekend does not put the entire universe in the backlog every Saturday.
  and (p.last_date is null or p.last_date < (now() at time zone 'utc')::date - 2)
  and (s.prices_missing_at is null or s.prices_missing_at < now() - interval '30 days')
group by s.security_id, sym.symbol, ps.symbol, p.last_date
order by best_weight desc;

comment on view market.pending_prices is
  'Securities whose stored price series is missing or stale, heaviest fund weight first. `last_date` is the newest bar held, so the resource fetches only what comes after it.';

grant select on market.pending_prices to service_role;

notify pgrst, 'reload schema';
