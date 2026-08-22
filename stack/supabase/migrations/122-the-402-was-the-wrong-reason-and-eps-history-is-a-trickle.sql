-- TWO THINGS, BOTH SETTLED BY MEASURING WITH A REAL KEY RATHER THAN REASONING FROM AN OLD NOTE.
--
-- ── 1. THE PEERS JUSTIFICATION WAS WRONG, AND THE DECISION WAS RIGHT ────────────────────────────
--
-- Migration 119 said `equity/compare/peers` could not serve the universe because "FMP's free tier
-- is per-SYMBOL (402s on NEE, PLD, BHP, SAP)". That is TRUE of
-- `equity/fundamental/revenue_per_geography` — measured 2026-08-22 with a live key, it answers for
-- AAPL/MSFT/NVDA/JPM/TSM and returns **402 for NEE, PLD, BHP, SAP.DE, 7203.T, 005930.KS and
-- SHEL.L** — and it is NOT true of `compare/peers`, which answered 8-10 rows for every one of
-- those thirteen symbols. I carried a limit from one endpoint to another because both are FMP.
--
-- The decision to compute peers here stands, for a reason worth more than the one I gave. FMP's
-- peers for AAPL are:
--
--     NVDA 5.20T · GOOGL 4.17T · MSFT 3.59T · TSM 2.17T · META 1.40T · SONY 140B
--     NXT 13.1B · TBCH 251M · RIME 852K
--
-- A list that puts an $852,000 company beside a $4tn one is a sector grab-bag, not a peer set. The
-- computed view is size-proximate BY CONSTRUCTION, which is the property the page needs. Correcting
-- the comment rather than the code, because the code was right.
--
-- ── 2. EPS HISTORY IS A TRICKLE, NOT A BACKLOG ──────────────────────────────────────────────────
--
-- `security_earnings_surprise` (migration 120) derives beat/miss from data already held, but only
-- for quarters inside `earnings_calendar`'s 90-day window. `equity/fundamental/historical_eps`
-- returns **122 quarters** of actual, estimate and surprise for AAPL — years of it.
--
-- Its constraint is absolute and shapes everything: alpha_vantage allows **25 calls a DAY**, and
-- FMP's copy of the same endpoint is **402 premium** (measured, even for AAPL), so there is no
-- second source. 12,350 equities at 25 a day is a year and a half; this can never be a backlog.
--
-- It CAN be a trickle. Three securities a run over eight runs is 24 calls a day, inside the limit,
-- and aimed at the largest fund holdings — ~500 of them refreshed quarterly is ~2,000 calls a year
-- against a ~9,000 budget. That is the difference between a feature that works for the pages people
-- open and one that fails on the 26th visitor.

comment on view market.security_peers is
  'Companies in the same sector of a similar size, computed from the materialised spine. NOT taken from `equity/compare/peers`: that endpoint answers for every symbol (measured — the per-symbol 402 belongs to `revenue_per_geography`, not to this one), but its list is not size-proximate — AAPL comes back beside NVDA at $5.2tn AND Algorhythm Holdings at $852,000. Size proximity is the property a comparison needs, so it is computed rather than fetched. Distance is a log ratio because a $40bn gap means one thing between two $50bn companies and nothing between two $2tn ones.';

insert into market.data_source (code, name, priority) values ('alpha-vantage', 'Alpha Vantage', 90)
on conflict (code) do nothing;

create table if not exists market.security_eps_history (
  security_id   uuid not null references market.security (security_id) on delete cascade,
  period_ending date not null,
  eps_actual    numeric,
  eps_estimated numeric,
  surprise      numeric,
  surprise_pct  numeric,
  reported_date date,
  source_code   text not null references market.data_source (code),
  as_of         timestamptz not null default now(),
  primary key (security_id, period_ending)
);

comment on table market.security_eps_history is
  'Actual versus estimated EPS per quarter, going back years — from `equity/fundamental/historical_eps`. Complements `security_earnings_surprise`, which derives the same fact from data already held but only for quarters inside the earnings calendar''s 90-day window.';

grant select on market.security_eps_history to anon, authenticated, service_role;
grant insert, update, delete on market.security_eps_history to service_role;

alter table market.security_eps_history enable row level security;
drop policy if exists security_eps_history_read on market.security_eps_history;
create policy security_eps_history_read on market.security_eps_history for select using (true);

alter table market.security add column if not exists eps_history_fetched_at timestamptz;

comment on column market.security.eps_history_fetched_at is
  'When deep EPS history was last fetched. A CURSOR at 90 days — a new quarter arrives four times a year, and the provider allows 25 calls a DAY in total, so re-asking sooner would spend the whole budget on securities that cannot have changed.';

drop view if exists market.pending_eps_history;
create view market.pending_eps_history as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  max(h.weight) as best_weight
from market.security s
join market.fund_holding_current h on h.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
where s.security_type_code = 'equity'
  and coalesce(ps.symbol, t.value) is not null
  and (s.eps_history_fetched_at is null
       or s.eps_history_fetched_at < now() - interval '90 days')
group by s.security_id, coalesce(ps.symbol, t.value)
-- THE TIGHTEST BOUND IN THE SCHEMA, and it has to be. 25 calls a DAY is ~9,000 a year; the top
-- holdings refreshed quarterly is ~2,000 of them. A looser threshold does not drain slower, it
-- exhausts the day's quota on the first cron run and fails every page-open after it.
having max(h.weight) >= 1.0
order by max(h.weight) desc;

comment on view market.pending_eps_history is
  'Equities that are at least 1% of some tracked fund and whose EPS history is unread or a quarter old. The tightest bound here on purpose: alpha_vantage allows 25 calls a DAY and FMP''s copy of the endpoint is premium, so there is no second source and no way to widen this.';

grant select on market.pending_eps_history to service_role;

notify pgrst, 'reload schema';
