-- DIVIDENDS REACH 4.5% OF THE UNIVERSE BECAUSE OF HOW WE ASK, NOT BECAUSE OF WHAT EXISTS.
--
-- `security_corporate_action` holds actions for **560 of 12,350 equities**. Measured 2026-08-19,
-- the shape of that gap is the tell:
--
--   US   361 of 2,874     JP   4 of 1,368     CN  65 of 2,374     IN  16 of 645
--
-- Even the United States is at 12.6%. That is not Tiingo being US-only — it is
-- `pending_corporate_actions` requiring `security_symbol = the US ticker`, so that the action and
-- the price series describe one listing. The constraint is correct for Tiingo (migration 68 deleted
-- 33 of 45 rows that violated it — a USD dividend recorded against a KRW price series) and it is
-- what limits coverage to securities whose primary listing IS their US line.
--
-- yfinance removes the constraint rather than working around it: we ask it with the SAME symbol we
-- price on, so the dividend and the bars describe one listing BY CONSTRUCTION. Measured against the
-- deployed openbb-api:
--
--   equity/fundamental/dividends?provider=yfinance   AAPL 92 rows (to 1987) · SAP.DE 28 · 7203.T 54
--
-- All three markets, at no new credential, from a provider we already call for the prices.
--
-- ── TIINGO IS NOT DELETED, IT IS DEMOTED ─────────────────────────────────────────────────────
--
-- yfinance's `equity/fundamental/dividends` returns dividends only. Splits still come from Tiingo,
-- so `pending_corporate_actions` and its US-ticker constraint stay exactly as they are. This adds a
-- second, wider backlog beside it rather than replacing one.
--
-- Both write `security_corporate_action`, whose PRIMARY KEY is (security_id, ex_date, kind) — so a
-- dividend seen by both providers is one row, and `source_code` records which wrote it last.
-- `observed_symbol` remains NOT NULL: an action without the listing it was seen on cannot be
-- checked against the series it is supposed to explain.

alter table market.security
  add column if not exists dividends_missing_at timestamptz;

comment on column market.security.dividends_missing_at is
  'Negative cache for `security-dividends`. SYMBOL-KEYED: yfinance is asked by the same symbol the prices use, so a corrected symbol must clear it.';

-- ── the negative cache must be declared, cleared and classified ──────────────────────────────
--
-- Three places, because getting this wrong has no symptom: the security simply goes quiet for 30
-- days while the resource reports ok. `negative-caches-are-classified.sql` fails CI on a
-- `%_missing_at` column nobody has decided about, which is what makes the omission loud.
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
    dividends_missing_at        = null
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
  ('figi_missing_at',              false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at',      false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at',      false, 'the resolver''s own flag — clearing it here would loop')
) as t(column_name, symbol_keyed, reason);

grant select on market.symbol_cache_classification to service_role;

-- ── the backlog ──────────────────────────────────────────────────────────────────────────────
--
-- NO US-TICKER CONSTRAINT, which is the entire point. `security_symbol` is what the bars are keyed
-- on and `security_provider_symbol` is what we ask the provider for — the same pair
-- `pending_prices` uses — so carrying both here means the dividend lands against the series it
-- belongs to without requiring the two to be a US listing.
--
-- Null-checks the FIRST left-joined table, the shape every draining backlog here has;
-- `pending_industry` once reached for a second table through an unrestricted join and re-asked the
-- same 300 securities for weeks while reporting progress.
drop view if exists market.pending_dividends;
create view market.pending_dividends as
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
  and (s.dividends_missing_at is null
       or s.dividends_missing_at < now() - interval '30 days')
  -- Re-ask every 30 days: a company that has never paid a dividend may start, and one that pays
  -- quarterly needs the new ex-date. The negative cache stops the never-payers dominating.
  and not exists (
    select 1 from market.security_corporate_action a
     where a.security_id = s.security_id
       and a.kind = 'dividend'
       and a.as_of > now() - interval '30 days'
  )
group by s.security_id, sym.symbol, ps.symbol
order by best_weight desc, s.security_id;

comment on view market.pending_dividends is
  'Equities needing a dividend refresh from yfinance. Unlike pending_corporate_actions this does NOT require the priced symbol to be the US ticker — yfinance is asked with the symbol the bars are keyed on, so the action and the series describe one listing by construction. That constraint is why Tiingo reaches 560 of 12,350.';

grant select on market.pending_dividends to service_role;

notify pgrst, 'reload schema';
