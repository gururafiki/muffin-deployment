-- A WRONG NAME IS NOT A MISSING SECURITY.
--
-- Measured against the deployed openbb-api — the left column is what this pipeline produces, the
-- right what the provider actually wants, and every left-hand spelling returns ZERO bars:
--
--   ATCOA.ST    -> 0     ATCO-A.ST  -> 190    Stockholm class shares take a hyphen
--   6.HK        -> 0     0006.HK    -> 190    Hong Kong tickers are zero-padded to four digits
--   BRK/B       -> 0     BRK-B      -> 190    a class slash is a hyphen at yfinance
--   WALMEX*.MX  -> 0     WALMEX.MX  -> 190    OpenFIGI's Bloomberg star is not part of the ticker
--   RR/.L       -> 0     RR.L       -> 190    ...and neither is a trailing slash
--
-- An empty response and a wrong name are indistinguishable from the caller, so the negative cache
-- records "this security has no data" and hides it for 30 days. That is how a perfectly ordinary
-- company disappears from the app with nothing logged.
--
-- ── THE BACKLOG IS THE MARKED SET, WHICH IS THE POINT ───────────────────────────────────────
--
-- A security is only worth re-spelling if asking under its current name has already failed. Any of
-- the price-related negative caches is evidence of that, so this resource reads them rather than
-- scanning the universe — the candidates cost a provider call each, and generating them for
-- 12,350 working symbols would be the expensive way to learn nothing.
--
-- ── AND ADOPTION REQUIRES THE PROVIDER TO ANSWER ────────────────────────────────────────────
--
-- The rules are generated liberally and verified individually, because pattern-matching alone
-- rewrites working symbols: the Nordic rule matches `SAND.ST` (Sandvik), `ALFA.ST` (Alfa Laval)
-- and `TELIA.ST`, which are complete company names ending in a letter the rule reads as a share
-- class. Repairing those would break three securities to fix one. `SAND.ST` therefore DOES
-- generate the candidate `SAN-D.ST` — and the provider refuses it, so nothing is written.

alter table market.security add column if not exists symbol_repair_at timestamptz;

comment on column market.security.symbol_repair_at is
  'When this security was last considered for a symbol repair — set whether or not one was found, so a security whose spelling is simply right is not re-tried every run. Keyed on the CIK-free provider symbol, and cleared by nothing: a repair that failed once can be retried after the window.';

-- ── the backlog ──────────────────────────────────────────────────────────────────────────────
drop view if exists market.pending_symbol_repair;

create view market.pending_symbol_repair as
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
  -- ONLY WHERE ASKING HAS ALREADY FAILED. Any price-related mark is the evidence; without this
  -- the resource would generate candidates for the whole universe and spend a call per security
  -- to confirm that working symbols work.
  and (s.prices_missing_at is not null
       or s.price_history_missing_at is not null
       or s.performance_missing_at is not null)
  -- Tried at most once a month, whether or not a repair was found: a security whose spelling is
  -- simply correct must not be re-examined every run for ever.
  and (s.symbol_repair_at is null or s.symbol_repair_at < now() - interval '30 days')
group by s.security_id, sym.symbol, coalesce(ps.symbol, sym.symbol)
order by best_weight desc, s.security_id;

comment on view market.pending_symbol_repair is
  'Securities whose price fetches have failed and whose symbol has not been re-examined this month, heaviest holding first. Reads the MARKED set on purpose: a candidate costs a provider call, and generating them for working symbols is the expensive way to learn nothing.';

grant select on market.pending_symbol_repair to service_role;

notify pgrst, 'reload schema';
