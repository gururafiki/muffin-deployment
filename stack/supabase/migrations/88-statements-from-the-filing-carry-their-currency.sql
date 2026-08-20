-- 104,972 STATEMENT ROWS AND NOT ONE CARRIES ITS CURRENCY.
--
-- `security_statement` has had a `currency` column and a `period_type` column since migration 29,
-- and `security-statements` already reads `reported_currency` and `fiscal_period` off the response.
-- Both are **0 of 104,972**, because yfinance sends neither. `data-ingestion.md` records this as
-- "the reporting currency of statements is unknown — five sources checked and none supplies it".
--
-- The sixth supplies it. Measured against the deployed openbb-api 2026-08-20:
--
--   equity/fundamental/income?provider=sec&symbol=AAPL&period=annual&limit=25
--     -> 18 rows, 2008-09-27 .. 2025-09-27, reported_currency = "USD", fiscal_period = "FY"
--
-- That is the documented gap closed AND history going from 4 periods to 18, in one change. The
-- currency matters beyond tidiness: it is what lets the app label a figure at all. Alibaba's CNY
-- revenue rendered as "$1.02T" — a real number under a wrong symbol — and the fix was to withhold
-- the label rather than guess it. `security.currency_code` is the QUOTE currency, which is not the
-- REPORTING currency; only the filing knows the latter.
--
-- ── SEC IS ANNUAL-ONLY HERE, AND THAT IS MEASURED RATHER THAN ASSUMED ────────────────────────
--
--   period=annual  limit=25  ->  18 rows
--   period=quarter limit=40  ->  HTTP 422
--
-- So this migration buys DEPTH and CURRENCY, not frequency. Quarterly history at 20 years needs
-- SEC's `companyfacts` XBRL endpoint directly, which is a separate piece of work.
--
-- ── WHY THE BACKLOG HAD TO CHANGE ────────────────────────────────────────────────────────────
--
-- `pending_statements` exits on `st.security_id is null` — "has no statements at all". Every one of
-- the 8,559 securities that already has four currency-less periods is therefore permanently out of
-- the queue, and a better provider would never reach them. The view now also admits a security
-- whose statements carry NO currency, which is exactly the population SEC can improve.
--
-- Scoped to securities with a US ticker, because that is what SEC is addressable by. Re-queueing
-- the rest would spend the provider budget re-fetching yfinance's same four periods — the
-- `provider_country_iso2` lesson: a backlog widened past the population the field serves is spend
-- with nothing to show. `SAP` and `TSM` resolve (foreign private issuers file 20-F), `SAP.DE` does
-- not, which is why the US ticker rather than the fetch symbol is the key.

-- ── THE SECOND POPULATION NEEDS ITS OWN NEGATIVE CACHE ──────────────────────────────────────
--
-- Widening a backlog to "wants X and does not have X" is how four separate resources here came to
-- re-ask a rate-limited provider forever for answers it will never have. This widening has exactly
-- that shape: a security with a US OTC line but no SEC filings (a foreign private issuer that files
-- nothing, a delisted shell) is queued for a currency, SEC answers nothing, yfinance re-writes the
-- same four currency-less periods, and it is queued again on the next run — for ever.
--
-- `statements_missing_at` cannot serve here, because these securities DO have statements; marking
-- them there would say something false about a different question.
--
-- NOT SYMBOL-KEYED, and that is the reason it is classified `false`. SEC is asked by the US TICKER,
-- so learning a better yfinance symbol says nothing about whether the company files with the SEC —
-- clearing it on a symbol correction would re-ask for an answer already held, the same mistake
-- `figi_missing_at` and `local_symbol_missing_at` are classified `false` to avoid.
alter table market.security
  add column if not exists statement_currency_missing_at timestamptz;

comment on column market.security.statement_currency_missing_at is
  'We asked SEC for this company''s filings and it had none, so its statements will keep their null currency. Keyed on the US TICKER, not the provider symbol — a corrected symbol must NOT clear it. 30 days, because a company can begin filing.';

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
  ('yahoo_symbol_missing_at',      false, 'the resolver''s own flag — clearing it here would loop'),
  ('statement_currency_missing_at', false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files')
) as t(column_name, symbol_keyed, reason);

grant select on market.symbol_cache_classification to service_role;

drop view if exists market.pending_statements;

create view market.pending_statements as
select
  s.security_id,
  -- What yfinance is asked for: the priced symbol, as before.
  coalesce(ps.symbol, t.value) as symbol,
  -- What SEC is asked for. NULL when there is no US line, and the resource then skips SEC entirely
  -- rather than sending it a symbol it cannot resolve.
  t.value                      as us_ticker,
  -- Why this security is queued, so a run can report which half of the backlog it drained. Same
  -- shape as `pending_profile.want` (migration 59).
  case when st.security_id is null then 'missing' else 'no_currency' end as want,
  coalesce(max(h.weight), 0)   as best_weight
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
-- NULL-checks the FIRST left-joined statement relation, the shape every draining backlog here has.
left join lateral (
  select x.security_id, count(*) filter (where x.currency is not null) as with_currency
    from market.security_statement x
   where x.security_id = s.security_id
   group by x.security_id
) st on true
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and coalesce(ps.symbol, t.value) is not null
  and (s.statements_missing_at is null or s.statements_missing_at < now() - interval '30 days')
  and (
    -- never fetched at all
    st.security_id is null
    -- or fetched, but by a provider that could not say what currency the filing is in, AND there
    -- is a US ticker for the provider that can, AND we have not already established that SEC has
    -- nothing for it
    or (
      st.with_currency = 0
      and t.value is not null
      and (s.statement_currency_missing_at is null
           or s.statement_currency_missing_at < now() - interval '30 days')
    )
  )
group by s.security_id, coalesce(ps.symbol, t.value), t.value, st.security_id, st.with_currency
order by best_weight desc, s.security_id;

comment on view market.pending_statements is
  'Equities needing statements. Two populations: never fetched, and fetched WITHOUT a reporting currency — the second is 8,559 securities that the old "has no statements at all" exit condition locked out permanently. `us_ticker` is what SEC is addressable by; NULL means SEC is skipped rather than asked with a symbol it cannot resolve.';

grant select on market.pending_statements to service_role;

notify pgrst, 'reload schema';
