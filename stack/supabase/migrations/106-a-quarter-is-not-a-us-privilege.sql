-- QUARTERLY FINANCIALS FOR THE 72% OF EQUITIES THAT DO NOT FILE WITH THE SEC.
--
-- Measured 2026-08-21 against the deployed view: AAPL, MSFT and NVDA return a P/E; SAP.DE, 7203.T,
-- 005930.KS, ASML.AS, TSM and BABA return NO ROWS AT ALL. Traced rather than guessed — SAP.DE has
-- price bars and statements back to 2016, and only ANNUAL metrics. `derive_ttm` needs four
-- consecutive quarters; quarters came only from SEC XBRL `companyfacts`, which needs a CIK. **3,516
-- securities have one against 12,350 equities**, so every price-based ratio was a US-only feature
-- and nothing said so — the section simply did not render.
--
-- The fix is one parameter. `equity/fundamental/income|balance|cash?provider=yfinance&period=quarter`
-- returns 5 quarterly periods for SAP.DE, Toyota, Samsung, ASML and Alibaba (probed against a LOCAL
-- openbb-api container, never bare against the shared node). The catalogue already carries
-- yfinance's spellings — `total_revenue`, `diluted_earnings_per_share`, `common_stock_equity` — so
-- no `metric_source_field` row changes; `derive_security_metrics` already maps `q%` to 'quarter'.
--
-- Nestlé returns nothing, and that is a FACT rather than a failure: Swiss issuers report
-- semi-annually. A negative cache is what stops us asking them again four times a day for ever.
--
-- ── WHY THE PRIMARY KEY HAS TO CHANGE ───────────────────────────────────────────────────────────
--
-- `security_statement` is keyed `(security_id, statement, period_ending)`, and a fiscal-year end is
-- BOTH an annual period and a fourth-quarter one. SAP's 2025-12-31 arrives twice with different
-- numbers, and the upsert would silently overwrite the annual figure with three months of it — a
-- revenue wrong by a factor of four, in the right units, with no error. `period_type` is already a
-- column and is NULL on all 107,172 existing rows (measured), every one of them annual, so the
-- backfill is exact rather than a guess.

-- Idempotent: NULL only exists before the first apply. After it, this matches nothing.
update market.security_statement set period_type = 'annual' where period_type is null;

alter table market.security_statement alter column period_type set default 'annual';
alter table market.security_statement alter column period_type set not null;

-- Re-runnable: only rebuild the key when it is still the three-column one.
do $$
declare k text;
begin
  select string_agg(a.attname, ',' order by x.ord)
    into k
  from pg_constraint c
  join lateral unnest(c.conkey) with ordinality as x(attnum, ord) on true
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = x.attnum
  where c.conrelid = 'market.security_statement'::regclass and c.contype = 'p'
  group by c.oid;

  if k is distinct from 'security_id,statement,period_ending,period_type' then
    alter table market.security_statement drop constraint if exists security_statement_pkey;
    alter table market.security_statement
      add constraint security_statement_pkey
      primary key (security_id, statement, period_ending, period_type);
  end if;
end $$;

-- The negative cache. A security whose provider carries no quarterly statements must leave the
-- backlog, or it crowds out the ones that would answer — the defect this file's own history
-- records four separate times.
alter table market.security add column if not exists quarters_missing_at timestamptz;

comment on column market.security.quarters_missing_at is
  'Set when the provider was asked for QUARTERLY statements alone and returned none. Swiss and some other issuers report semi-annually, so this is an ordinary permanent answer rather than a fault.';

-- A NEW SYMBOL INVALIDATES IT, because the question was asked under the old spelling. Added to the
-- shared function rather than to a caller, which is the whole point of migration 50 existing.
--
-- BOTH LISTS ARE COPIED FROM MIGRATION 097, NOT FROM 050. These are `create or replace`, so the
-- LAST file to run wins outright — starting from migration 50's nine entries silently deletes the
-- eight that 059/067/087/088/094/095/097 added, and the classification test fails naming all eight.
-- (It did, on the first run of this file. The test is the only reason that was not a silent
-- regression of every negative cache added in the last three weeks.)
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
    price_history_missing_at    = null,
    share_stats_missing_at      = null,
    estimates_missing_at        = null,
    quarters_missing_at         = null
  where security_id = p_security_id;
$$;

grant execute on function market.clear_symbol_caches(uuid) to service_role;

-- `negative-caches-are-classified.sql` fails CI on any `%_missing_at` column nobody classified.
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
  ('share_stats_missing_at',       true,  'share statistics fetched by the PRICED symbol'),
  ('estimates_missing_at',         true,  'analyst consensus fetched by the PRICED symbol'),
  ('figi_missing_at',              false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at',      false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at',      false, 'the resolver''s own flag — clearing it here would loop'),
  ('statement_currency_missing_at', false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'),
  ('xbrl_missing_at',              false, 'company facts are asked for by CIK; a new provider symbol says nothing about the filer')
) as t(column_name, symbol_keyed, reason);

comment on view market.symbol_cache_classification is
  'Which negative caches a new symbol invalidates, and why. Enforced by tests/negative-caches-are-classified.sql: a `%_missing_at` column missing from here fails CI.';

grant select on market.symbol_cache_classification to service_role;

-- ── THE BACKLOG ─────────────────────────────────────────────────────────────────────────────────
--
-- SCOPED, NOT UNIVERSAL. Quarterly does not batch — measured: two symbols return zero rows, which
-- is the same reason `STMT_BATCH` is already 1 — so this costs THREE calls per security against a
-- rate-limited provider. Asking it of all 8,834 non-SEC equities would spend months of the shared
-- budget and starve every other backlog. So:
--
--   * SEC filers are excluded: `security-xbrl` already gives them 17 years of quarters, and asking
--     yfinance for 5 would be paying to overwrite the better record.
--   * a security must ALREADY have annual statements, which proves the provider answers for this
--     symbol at all. Without that this backlog would be a list of things to fail at.
--   * ordered by FUND WEIGHT, not market cap — a percentage is free of currency, cap and country,
--     and 34% of the universe still has no cap at all.
--
-- The anti-join is over the ENTITY (does this security have ANY quarterly statement) rather than a
-- `where` over rows: a `where` filters rows, not securities, and one qualifying row cannot suppress
-- another. That is the defect that kept `pending_industry` re-fetching the same 300 rows for months.
drop view if exists market.pending_quarters;
create view market.pending_quarters as
select
  s.security_id,
  -- The FETCH key, which is not the display symbol: `security_provider_symbol` carries the local
  -- listing yfinance actually answers for (SAP.DE, not the SAPGF OTC line the ticker resolves to).
  coalesce(ps.symbol, t.value) as symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and s.cik is null
  and coalesce(ps.symbol, t.value) is not null
  and (s.quarters_missing_at is null or s.quarters_missing_at < now() - interval '30 days')
  -- Proves the provider answers for this symbol; without it the backlog is a list of failures.
  and exists (
    select 1 from market.security_statement a
     where a.security_id = s.security_id and a.period_type = 'annual'
  )
  and not exists (
    select 1 from market.security_statement q
     where q.security_id = s.security_id and q.period_type = 'quarter'
  )
group by s.security_id, coalesce(ps.symbol, t.value)
order by best_weight desc;

comment on view market.pending_quarters is
  'Non-SEC equities with annual statements but no quarterly ones, ordered by fund weight. Quarterly does not batch (3 calls per security), so this is deliberately scoped rather than the whole universe — SEC filers already have 17 years of quarters from companyfacts.';

grant select on market.pending_quarters to service_role;

notify pgrst, 'reload schema';
