-- SEVENTEEN YEARS OF STATEMENTS, QUARTERLY, IN ONE REQUEST PER COMPANY.
--
-- `security-statements` fetches three openbb calls per security and gets 18 ANNUAL periods. Timed
-- on the deployed openbb-api: income 1.94s, balance 1.88s, cash 1.77s — **5.58s per security**, so
-- 16 securities per 90-second worker. Against a backlog of 8,633 that is 67 days, and it can never
-- produce a quarterly figure at all (`period=quarter` answers 422).
--
-- Concurrency does not fix it. Measured: three parallel calls for one security take 5.53s, the
-- same as sequential — openbb-api serialises them. Twelve-way concurrency across four securities
-- got 5.58s down to 3.57s, a 1.6x win for 12x the load on a SHARED 1 GB container. The bottleneck
-- is the mediator, so the answer is fewer requests, not more of them at once.
--
-- SEC's own XBRL API, from the same node:
--
--   company_tickers.json                 776 KB   0.18s   10,387 filers
--   companyfacts/CIK0000320193.json      3.6 MB   0.17s   503 us-gaap concepts
--
-- One request, 0.17s, and it carries **fy 2009..2026 with FY, Q1, Q2 and Q3** — seventeen years
-- including quarterly, against openbb's 18 annual points at 33x the cost.
--
-- ── WHY CONCEPTS ARE A TABLE, AND WHY RESOLUTION IS PER PERIOD ───────────────────────────────
--
-- A metric does not map to one XBRL concept. Measured across five filers 2026-08-20:
--
--   revenue       JPM, CAT     -> Revenues
--                 AAPL, WMT, PFE -> RevenueFromContractWithCustomerExcludingAssessedTax
--   total_equity  most         -> StockholdersEquity
--                 CAT          -> StockholdersEquityIncludingPortionAttributableToNoncontrolling...
--
-- So each metric gets a PRIORITY-ORDERED CANDIDATE LIST, the same shape `metric_source_field`
-- already uses for provider field names one level up.
--
-- And the resolution is PER PERIOD, not per company. CAT reports `NetIncomeLoss` only for fy
-- 2009..2011 and something else afterwards, so "the first concept that has any data" picks a
-- concept that covers three years and silently truncates the other fourteen. For each period,
-- take the highest-priority concept that has a value FOR THAT PERIOD.
--
-- ── PROVENANCE BEATS RECENCY ────────────────────────────────────────────────────────────────
--
-- These rows land in `security_metric` beside ones derived from yfinance statements, on the same
-- primary key. A filing beats a provider's summary, so `sec-xbrl` is seeded at a HIGHER
-- `data_source.priority` and the derivation is taught not to overwrite a higher-priority row with
-- a lower-priority one. Without that, whichever resource ran last would win, and the answer would
-- change depending on cron ordering.

insert into market.data_source (code, name, priority) values
  ('sec-xbrl', 'SEC XBRL company facts', 275)
on conflict (code) do nothing;

-- ── the filer id ─────────────────────────────────────────────────────────────────────────────
-- NOT UNIQUE: share classes share a filer. GOOG and GOOGL are both CIK 1652044, and a unique
-- index would make ingesting the second one fail.
alter table market.security add column if not exists cik integer;
alter table market.security add column if not exists xbrl_fetched_at timestamptz;
alter table market.security add column if not exists xbrl_missing_at timestamptz;

create index if not exists security_cik_idx on market.security (cik) where cik is not null;

comment on column market.security.cik is
  'SEC filer id, from company_tickers.json matched on the US ticker. NOT unique — share classes share a filer (GOOG and GOOGL are both 1652044).';
comment on column market.security.xbrl_missing_at is
  'We asked SEC for this filer''s company facts and got nothing usable. Keyed on the CIK, so a corrected provider SYMBOL says nothing about it and must not clear it.';

-- ── the concept catalogue ────────────────────────────────────────────────────────────────────
create table if not exists market.xbrl_concept (
  metric_code text not null references market.metric (code) on delete cascade,
  concept     text not null,
  -- Higher wins, evaluated PER PERIOD. A company that switches concepts mid-history gets a
  -- continuous series instead of one that stops the year it switched.
  priority    integer not null default 100,
  -- The `units` key inside companyfacts: 'USD' for money, 'USD/shares' for per-share, 'shares'
  -- for counts. It also decides whether the row carries a currency at all.
  unit        text not null default 'USD',
  primary key (metric_code, concept)
);

comment on table market.xbrl_concept is
  'Which XBRL concepts express each metric, priority-ordered. Measured, not guessed: JPM and CAT report revenue as `Revenues` while AAPL, WMT and PFE use `RevenueFromContractWithCustomerExcludingAssessedTax`. Resolution is per PERIOD — CAT reports NetIncomeLoss only for 2009..2011.';

insert into market.xbrl_concept (metric_code, concept, priority, unit) values
  ('revenue',             'RevenueFromContractWithCustomerExcludingAssessedTax', 100, 'USD'),
  ('revenue',             'RevenueFromContractWithCustomerIncludingAssessedTax',  90, 'USD'),
  ('revenue',             'Revenues',                                             80, 'USD'),
  ('revenue',             'SalesRevenueNet',                                      70, 'USD'),
  ('net_income',          'NetIncomeLoss',                                       100, 'USD'),
  ('net_income',          'ProfitLoss',                                           90, 'USD'),
  ('gross_profit',        'GrossProfit',                                         100, 'USD'),
  ('operating_income',    'OperatingIncomeLoss',                                 100, 'USD'),
  ('pretax_income',       'IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest', 100, 'USD'),
  ('pretax_income',       'IncomeLossFromContinuingOperationsBeforeIncomeTaxesMinorityInterestAndIncomeLossFromEquityMethodInvestments', 90, 'USD'),
  ('income_tax',          'IncomeTaxExpenseBenefit',                             100, 'USD'),
  ('rd_expense',          'ResearchAndDevelopmentExpense',                       100, 'USD'),
  ('sga_expense',         'SellingGeneralAndAdministrativeExpense',              100, 'USD'),
  ('total_assets',        'Assets',                                              100, 'USD'),
  ('total_liabilities',   'Liabilities',                                         100, 'USD'),
  ('total_equity',        'StockholdersEquity',                                  100, 'USD'),
  ('total_equity',        'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest', 90, 'USD'),
  ('cash_and_equivalents','CashAndCashEquivalentsAtCarryingValue',               100, 'USD'),
  ('long_term_debt',      'LongTermDebtNoncurrent',                              100, 'USD'),
  ('long_term_debt',      'LongTermDebt',                                         90, 'USD'),
  ('short_term_debt',     'LongTermDebtCurrent',                                 100, 'USD'),
  ('operating_cash_flow', 'NetCashProvidedByUsedInOperatingActivities',          100, 'USD'),
  ('operating_cash_flow', 'NetCashProvidedByUsedInOperatingActivitiesContinuingOperations', 90, 'USD'),
  ('capital_expenditure', 'PaymentsToAcquirePropertyPlantAndEquipment',          100, 'USD'),
  ('buyback',             'PaymentsForRepurchaseOfCommonStock',                  100, 'USD'),
  ('stock_based_comp',    'ShareBasedCompensation',                              100, 'USD'),
  ('dividends_paid',      'PaymentsOfDividendsCommonStock',                      100, 'USD'),
  ('dividends_paid',      'PaymentsOfDividends',                                  90, 'USD'),
  ('eps_basic',           'EarningsPerShareBasic',                               100, 'USD/shares'),
  ('eps_diluted',         'EarningsPerShareDiluted',                             100, 'USD/shares'),
  ('shares_basic',        'WeightedAverageNumberOfSharesOutstandingBasic',       100, 'shares'),
  ('shares_diluted',      'WeightedAverageNumberOfDilutedSharesOutstanding',     100, 'shares')
on conflict (metric_code, concept) do update set
  priority = excluded.priority, unit = excluded.unit;

grant select on market.xbrl_concept to anon, authenticated, service_role;
grant insert, update, delete on market.xbrl_concept to service_role;
alter table market.xbrl_concept enable row level security;
do $$ begin
  create policy xbrl_concept_public_read on market.xbrl_concept for select using (true);
exception when duplicate_object then null; end $$;

-- ── the backlog ──────────────────────────────────────────────────────────────────────────────
-- Keyed on WHEN WE LAST ASKED, not on whether rows exist. A filer publishes new quarters, so this
-- is a refresh rather than a one-off — and "has no sec-xbrl metric" would re-ask for ever for the
-- filers whose facts carry none of the catalogued concepts.
drop view if exists market.pending_xbrl;

create view market.pending_xbrl as
select
  s.security_id,
  s.cik,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.fund_holding_current h on h.security_id = s.security_id
where s.cik is not null
  and s.security_type_code = 'equity'
  and (s.xbrl_fetched_at is null or s.xbrl_fetched_at < now() - interval '30 days')
  and (s.xbrl_missing_at is null or s.xbrl_missing_at < now() - interval '30 days')
group by s.security_id, s.cik
order by best_weight desc, s.security_id;

comment on view market.pending_xbrl is
  'US filers whose company facts have not been read in 30 days, heaviest fund holding first. Keyed on when we last ASKED rather than on whether rows exist, so a filer using none of the catalogued concepts is not re-asked for ever.';

grant select on market.pending_xbrl to service_role;

-- ── the negative cache classification ────────────────────────────────────────────────────────
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
  ('statement_currency_missing_at', false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'),
  ('xbrl_missing_at',              false, 'company facts are asked for by CIK; a new provider symbol says nothing about the filer')
) as t(column_name, symbol_keyed, reason);

grant select on market.symbol_cache_classification to service_role;

-- ── a filing must not be overwritten by a provider's summary ────────────────────────────────
-- `derive_security_metrics` upserts with `do update` unconditionally, so whichever resource ran
-- last would win and the served number would depend on cron ordering. The rule is priority:
-- `sec-xbrl` (275) beats `sec` (250) beats `yfinance` (100), and `derived` (50) beats nothing.
create or replace function market.source_priority(p_code text)
returns integer language sql stable as $$
  select coalesce((select priority from market.data_source where code = p_code), 0);
$$;

revoke execute on function market.source_priority(text) from public;
grant execute on function market.source_priority(text) to service_role, anon, authenticated;

notify pgrst, 'reload schema';

-- The derivation is re-created here (rather than edited in place in migration 93) because
-- migrations re-run in order and 93 would otherwise restore the unguarded version on every deploy.
create or replace function market.derive_security_metrics(p_limit integer default null)
returns integer
language plpgsql
as $$
declare
  v_written integer := 0;
  v_extra   integer := 0;
begin
  create temporary table _touched on commit drop as
  with src as (
    select st.security_id, st.period_ending, st.currency, st.source_code,
           coalesce(st.period_type, 'annual') as period_type,
           st.statement, st.data
      from market.security_statement st
     where not exists (
       select 1
         from market.security_metric sm
         join market.metric_source_field f2
           on f2.metric_code = sm.metric_code
          and f2.source_code = st.source_code
          and f2.statement   = st.statement
        where sm.security_id = st.security_id
          and sm.as_of       = st.period_ending
          and sm.fetched_at >= st.as_of)
     order by st.as_of
     limit p_limit
  ),
  ins as (
    insert into market.security_metric
      (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
    select
      src.security_id,
      f.metric_code,
      case when lower(src.period_type) in ('fy', 'annual') then 'annual'
           when lower(src.period_type) like 'q%'           then 'quarter'
           else lower(src.period_type) end,
      src.period_ending,
      (src.data ->> f.field)::numeric,
      src.currency,
      src.source_code,
      now()
    from src
    join market.metric_source_field f
      on f.source_code = src.source_code
     and f.statement   = src.statement
    where jsonb_typeof(src.data -> f.field) = 'number'
    on conflict (security_id, metric_code, period_type, as_of) do update
      set value = excluded.value,
          currency_code = excluded.currency_code,
          source_code = excluded.source_code,
          fetched_at = excluded.fetched_at
      -- A FILING BEATS A PROVIDER'S SUMMARY. Without this the resource that ran last wins and the
      -- served number depends on cron ordering — 17 years of XBRL quietly replaced by 4 periods of
      -- yfinance, with nothing to show for it but a shorter chart.
      where market.source_priority(excluded.source_code)
         >= market.source_priority(market.security_metric.source_code)
    returning security_id, period_type, as_of
  )
  select security_id, period_type, as_of from ins;

  get diagnostics v_written = row_count;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select ocf.security_id, 'free_cash_flow', ocf.period_type, ocf.as_of,
         ocf.value - abs(capex.value), ocf.currency_code, 'derived', now()
    from market.security_metric ocf
    join (select distinct security_id, period_type, as_of from _touched) t
      on t.security_id = ocf.security_id and t.period_type = ocf.period_type and t.as_of = ocf.as_of
    join market.security_metric capex
      on capex.security_id = ocf.security_id
     and capex.period_type = ocf.period_type
     and capex.as_of       = ocf.as_of
     and capex.metric_code = 'capital_expenditure'
   where ocf.metric_code = 'operating_cash_flow'
     and not exists (
       select 1 from market.security_metric x
        where x.security_id = ocf.security_id and x.period_type = ocf.period_type
          and x.as_of = ocf.as_of and x.metric_code = 'free_cash_flow'
          and x.source_code <> 'derived')
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select ltd.security_id, 'total_debt', ltd.period_type, ltd.as_of,
         ltd.value + coalesce(std.value, 0), ltd.currency_code, 'derived', now()
    from market.security_metric ltd
    join (select distinct security_id, period_type, as_of from _touched) t
      on t.security_id = ltd.security_id and t.period_type = ltd.period_type and t.as_of = ltd.as_of
    left join market.security_metric std
      on std.security_id = ltd.security_id
     and std.period_type = ltd.period_type
     and std.as_of       = ltd.as_of
     and std.metric_code = 'short_term_debt'
   where ltd.metric_code = 'long_term_debt'
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  drop table _touched;
  return v_written;
end;
$$;

revoke execute on function market.derive_security_metrics(integer) from public;
grant execute on function market.derive_security_metrics(integer) to service_role;

notify pgrst, 'reload schema';
