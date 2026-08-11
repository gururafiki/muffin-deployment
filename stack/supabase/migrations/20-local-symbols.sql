-- Address non-US securities the way the price provider does — IDEMPOTENT.
--
-- Everything non-US was capped by one chain: ticker resolution asked OpenFIGI for the US listing,
-- and a company with no US line got no ticker — so no profile, so no sector, and no price. Measured
-- 2026-08-11: Korea had 10 tickers across 467 securities and exactly ONE classified sector, while
-- Germany, which has plenty of US OTC lines, had 107 of 153.
--
-- `security_provider_symbol` already existed for exactly this (the NESN -> NESN.SW special case);
-- it was simply never populated at scale.

alter table market.security add column if not exists local_symbol_missing_at timestamptz;
comment on column market.security.local_symbol_missing_at is
  'When the local-listing lookup last found nothing addressable. Excludes it from pending_local_symbol for 30 days.';

-- The backlog: has an ISIN, is in a country with a local venue, has no provider symbol yet.
create or replace view market.pending_local_symbol as
select
  s.security_id,
  s.country_iso2,
  isin.value as isin,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier isin
  on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where ps.security_id is null
  and s.security_type_code = 'equity'
  and s.country_iso2 is not null
  and s.country_iso2 <> 'US'
  and (s.local_symbol_missing_at is null or s.local_symbol_missing_at < now() - interval '30 days')
group by s.security_id, s.country_iso2, isin.value
order by best_weight desc;

grant select on market.pending_local_symbol to service_role;

-- ── the two backlogs now PREFER the provider symbol ──────────────────────────
-- A security's yfinance address is `005930.KS`, not `005930`, and not the thin US OTC line. Both
-- resources fetch by whatever these views hand them, so this is the single place that decides.

-- DROP, not CREATE OR REPLACE: Postgres refuses to rename or reorder a view's columns
-- ("cannot change name of view column"), and `pending_performance` gains a `fetch_symbol` column
-- ahead of `best_weight`. Replace-in-place only ever appends. Nothing depends on these two, so a
-- drop is safe; a view that something else selects from would need CASCADE and a rebuild.
drop view if exists market.pending_profile;
create view market.pending_profile as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  s.name,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_taxonomy st
  on st.security_id = s.security_id and st.source_code = 'yfinance'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where st.security_id is null
  and s.security_type_code = 'equity'
  and coalesce(ps.symbol, t.value) is not null
  and (s.profile_missing_at is null or s.profile_missing_at < now() - interval '30 days')
group by s.security_id, coalesce(ps.symbol, t.value), s.name
order by best_weight desc;

grant select on market.pending_profile to service_role;

-- Performance is keyed on the DISPLAY ticker, not the provider one: the app looks a stock up by
-- the symbol it shows. So this returns both — what to fetch, and what to store it under.
drop view if exists market.pending_performance;
create view market.pending_performance as
select
  s.security_id,
  coalesce(t.value, ps.symbol) as symbol,
  coalesce(ps.symbol, t.value) as fetch_symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.performance p
  on p.scope = 'instrument' and p.scope_id = coalesce(t.value, ps.symbol) and p.stale_after > now()
left join market.fund_holding_current h
  on h.security_id = s.security_id
where p.scope_id is null
  and s.security_type_code = 'equity'
  and coalesce(t.value, ps.symbol) is not null
group by s.security_id, coalesce(t.value, ps.symbol), coalesce(ps.symbol, t.value)
order by best_weight desc;

grant select on market.pending_performance to service_role;

notify pgrst, 'reload schema';
