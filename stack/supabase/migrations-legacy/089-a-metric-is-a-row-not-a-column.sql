-- A METRIC IS A ROW, NOT A COLUMN — and the provider's spelling for it is a row too.
--
-- `security_fundamentals` is 17 columns and exactly ONE ROW PER SECURITY: the latest value, no
-- history. `security_statement` holds history but as raw provider jsonb, so nothing can chart it
-- without knowing which provider wrote each period. This migration adds the shape that
-- `macro_observation` has been using successfully since migration 82 — long, historical, one row
-- per (entity, metric, period) — for companies.
--
-- ── THE MEASUREMENT THAT FORCED THE MAPPING TABLE ────────────────────────────────────────────
--
-- Migration 88 made SEC the preferred statement provider. Measured on the deployed openbb-api
-- 2026-08-20, AAPL annual, the two providers' income statements share **4 of 40 field names** —
-- and one of the four is `period_ending`, which is not data:
--
--   concept          sec                              yfinance
--   pre-tax income   total_pretax_income              total_pre_tax_income      <- ONE CHARACTER
--   basic EPS        basic_eps                        basic_earnings_per_share
--   diluted shares   weighted_ave_diluted_shares_os   weighted_average_diluted_shares_outstanding
--   income tax       income_tax_expense               tax_provision
--   operating CF     net_cash_from_operating_activities  operating_cash_flow
--   capex            purchase_of_plant_property_and_equipment  capital_expenditure
--   free cash flow   — ABSENT —                       free_cash_flow
--   dividends paid   payment_of_dividends             cash_dividends_paid
--
-- Balance sheets share 14 of 52/70, cash flows 8 of 45/54. So `security_statement.data` now holds
-- TWO INCOMPATIBLE VOCABULARIES, and any reader written as `data->>'free_cash_flow'` silently
-- returns null for every SEC period — which, after 88, is the better half of the data. A single
-- hardcoded lookup cannot be right; a `case` over providers would be the same fact in two places,
-- which this codebase has already watched drift (the venue map, 54 rows against 38).
--
-- Hence `metric_source_field`: which provider spells a metric how is a ROW, so a third provider is
-- a row and not a code change. Seeded ONLY with names measured off the wire above — nothing is
-- authored from memory, because authoring reference data from memory is what silently dropped
-- Taiwan from the country list.
--
-- ── WHAT THIS DOES NOT DO ───────────────────────────────────────────────────────────────────
--
-- It does not populate anything. `security_metric` is filled by derivation from statements,
-- prices and dividends — a later change — and this one is deliberately inert so the schema can be
-- reviewed and applied without a single provider call.
--
-- It also does not touch `security_fundamentals`, which stays as the provider's LATEST-RATIO
-- snapshot with live readers (`security_style`, `security_current`, the app's use-fundamentals).
-- The boundary that keeps them from becoming two answers to one question: `security_metric` holds
-- INPUTS THE FILING REPORTS, `security_fundamentals` holds RATIOS A PROVIDER COMPUTED, and no
-- metric seeded here duplicates a `security_fundamentals` column. Ratios belong in a view over
-- price x metric, where the inputs are visible — the way financecharts exposes `ADJ close` and
-- `DILUTED EPS TTM` beside a P/E rather than storing the P/E.

-- ── FIRST, THE SOURCE THAT MIGRATION 88 FORGOT TO REGISTER ──────────────────────────────────
--
-- A LIVE FAILURE, not a hypothetical: migration 88 made `security-statements` write
-- `source_code: 'sec'`, and no migration had ever created that row. `security_statement.source_code`
-- is a foreign key to `data_source`, so the first real run died with
--
--   security_statement upsert failed: insert or update on table "security_statement"
--   violates foreign key constraint "security_statement_source_code_fkey"
--
-- and took the whole resource with it — including the yfinance rows in the same batch. Only
-- `sec-nport` existed, which is a different filing entirely (fund holdings, not company accounts).
--
-- Migration 67 got this right for Tiingo: it seeded the source in the same migration that
-- introduced the resource writing it. 88 did not, and nothing could catch it, because the
-- migration tests apply to a database where the resource never runs and the FK is never exercised.
-- `logic-check.ts` now fails on any `source_code: '<x>'` literal in the functions that no migration
-- seeds — the offline guard that would have caught this before it shipped.
--
-- Priority 250: a filing beats a provider's opinion (yfinance is 100), while N-PORT keeps 300
-- because holdings are its subject and it is the only source for them.
insert into market.data_source (code, name, priority) values
  ('sec', 'SEC company filings (10-K/20-F)', 250)
on conflict (code) do nothing;

-- ── the catalogue ────────────────────────────────────────────────────────────────────────────
create table if not exists market.metric (
  code        text primary key,
  name        text not null,
  -- income_statement | balance_sheet | cash_flow | share | dividend
  category    text not null,
  -- currency | shares | ratio | percent. Drives FORMATTING, and formatting has been wrong here
  -- twice: a fraction rendered as a percent (a 46% dividend yield) and money rendered with an
  -- assumed `$` (Alibaba's CNY revenue as $1.02T).
  unit        text not null,
  -- True when no provider reports it and it is computed from other metrics (free cash flow from
  -- SEC periods, total debt from its two halves). Recorded so a reader can tell a reported number
  -- from an arithmetic one.
  is_derived  boolean not null default false,
  sort_order  integer not null default 100,
  notes       text
);

create table if not exists market.metric_source_field (
  metric_code text not null references market.metric (code) on delete cascade,
  source_code text not null references market.data_source (code),
  -- 'income' | 'balance' | 'cash' — which statement of that provider's carries it.
  statement   text not null,
  -- The provider's own key inside `security_statement.data`.
  field       text not null,
  primary key (metric_code, source_code)
);

comment on table market.metric is
  'The metrics this deployment can chart, as a CONTROL TABLE — adding one is a row, the same shape as tracked_fund and macro_indicator. Holds INPUTS the filing reports; ratios are derived over price x metric rather than stored, so the two numbers behind a P/E stay visible.';
comment on table market.metric_source_field is
  'How each provider spells each metric. Measured, not assumed: sec and yfinance share 4 of 40 income-statement field names, and one of the four is period_ending. A hardcoded lookup or a case-over-providers would be the same fact in two places.';

-- ── the series ───────────────────────────────────────────────────────────────────────────────
create table if not exists market.security_metric (
  security_id   uuid not null references market.security (security_id) on delete cascade,
  metric_code   text not null references market.metric (code),
  -- 'annual' | 'quarter' | 'ttm'. In the KEY, not beside it: the same period end legitimately
  -- carries an annual figure and a TTM figure, and they are different facts.
  period_type   text not null,
  as_of         date not null,
  value         numeric not null,
  -- MONEY CARRIES ITS CURRENCY. Alibaba's CNY 1,023,670,000,000 revenue rendered as "$1.02T" —
  -- the largest company on earth by revenue against a true ~$141bn — because the figure travelled
  -- without it. Null where the metric is a ratio or a share count.
  currency_code text references market.currency (code),
  source_code   text not null references market.data_source (code),
  fetched_at    timestamptz not null default now(),
  primary key (security_id, metric_code, period_type, as_of)
);

create index if not exists security_metric_series_idx
  on market.security_metric (security_id, metric_code, period_type, as_of desc);

comment on table market.security_metric is
  'One value per (security, metric, period type, period end) — the shape macro_observation already uses for countries, so a company metric and a country metric differ only in what they hang off.';
comment on column market.security_metric.period_type is
  'Part of the KEY. One period end carries both an annual and a TTM figure and they are different facts; keeping this beside the key would let one overwrite the other.';

-- ── the seed: ONLY field names measured off the wire ─────────────────────────────────────────
insert into market.metric (code, name, category, unit, is_derived, sort_order, notes) values
  ('revenue',          'Revenue',                 'income_statement', 'currency', false, 10,  null),
  ('gross_profit',     'Gross profit',            'income_statement', 'currency', false, 20,  null),
  ('operating_income', 'Operating income',        'income_statement', 'currency', false, 30,  null),
  ('pretax_income',    'Pre-tax income',          'income_statement', 'currency', false, 40,  'sec spells this total_pretax_income and yfinance total_pre_tax_income — one character apart, which is exactly why the spelling is a row'),
  ('income_tax',       'Income tax',              'income_statement', 'currency', false, 50,  null),
  ('net_income',       'Net income',              'income_statement', 'currency', false, 60,  'one of only four income-statement field names the two providers share'),
  ('rd_expense',       'Research & development',  'income_statement', 'currency', false, 70,  null),
  ('sga_expense',      'Selling, general & admin','income_statement', 'currency', false, 80,  null),
  ('eps_basic',        'EPS (basic)',             'income_statement', 'currency', false, 90,  null),
  ('eps_diluted',      'EPS (diluted)',           'income_statement', 'currency', false, 100, null),
  ('shares_basic',     'Shares outstanding (basic)',   'share', 'shares', false, 110, null),
  ('shares_diluted',   'Shares outstanding (diluted)', 'share', 'shares', false, 120, null),
  ('total_assets',     'Total assets',            'balance_sheet', 'currency', false, 130, null),
  ('total_liabilities','Total liabilities',       'balance_sheet', 'currency', false, 140, null),
  ('total_equity',     'Total equity',            'balance_sheet', 'currency', false, 150, null),
  ('cash_and_equivalents','Cash & equivalents',   'balance_sheet', 'currency', false, 160, null),
  ('long_term_debt',   'Long-term debt',          'balance_sheet', 'currency', false, 170, null),
  ('short_term_debt',  'Short-term debt',         'balance_sheet', 'currency', false, 180, 'sec reports this directly; yfinance''s nearest is the current portion of long-term debt, so total_debt is derived rather than read'),
  ('operating_cash_flow','Operating cash flow',   'cash_flow', 'currency', false, 190, null),
  ('capital_expenditure','Capital expenditure',   'cash_flow', 'currency', false, 200, 'sign differs by provider — normalised at derivation, not here'),
  ('buyback',          'Share repurchases',       'cash_flow', 'currency', false, 210, null),
  ('stock_based_comp', 'Stock-based compensation','cash_flow', 'currency', false, 220, null),
  ('dividends_paid',   'Dividends paid',          'cash_flow', 'currency', false, 230, null),
  -- DERIVED: no provider reports these for every source, so they are arithmetic and say so.
  ('free_cash_flow',   'Free cash flow',          'cash_flow', 'currency', true,  240, 'yfinance reports it; SEC does NOT, so for a SEC period it is operating cash flow minus capital expenditure'),
  ('total_debt',       'Total debt',              'balance_sheet', 'currency', true,  250, 'SEC reports short_term_debt and long_term_debt separately and no total; summed rather than read')
on conflict (code) do update set
  name = excluded.name, category = excluded.category, unit = excluded.unit,
  is_derived = excluded.is_derived, sort_order = excluded.sort_order, notes = excluded.notes;

-- Measured against the deployed openbb-api on 2026-08-20 (AAPL, period=annual). A metric with no
-- row for a source simply is not available from it — `free_cash_flow` and `total_debt` have no sec
-- row on purpose, which is what marks them derived for that provider.
insert into market.metric_source_field (metric_code, source_code, statement, field) values
  ('revenue',            'sec',      'income',  'total_revenue'),
  ('revenue',            'yfinance', 'income',  'total_revenue'),
  ('gross_profit',       'sec',      'income',  'total_gross_profit'),
  ('gross_profit',       'yfinance', 'income',  'gross_profit'),
  ('operating_income',   'sec',      'income',  'total_operating_income'),
  ('operating_income',   'yfinance', 'income',  'operating_income'),
  ('pretax_income',      'sec',      'income',  'total_pretax_income'),
  ('pretax_income',      'yfinance', 'income',  'total_pre_tax_income'),
  ('income_tax',         'sec',      'income',  'income_tax_expense'),
  ('income_tax',         'yfinance', 'income',  'tax_provision'),
  ('net_income',         'sec',      'income',  'net_income'),
  ('net_income',         'yfinance', 'income',  'net_income'),
  ('rd_expense',         'sec',      'income',  'rd_expense'),
  ('rd_expense',         'yfinance', 'income',  'research_and_development_expense'),
  ('sga_expense',        'sec',      'income',  'sga_expense'),
  ('sga_expense',        'yfinance', 'income',  'selling_general_and_admin_expense'),
  ('eps_basic',          'sec',      'income',  'basic_eps'),
  ('eps_basic',          'yfinance', 'income',  'basic_earnings_per_share'),
  ('eps_diluted',        'sec',      'income',  'diluted_eps'),
  ('eps_diluted',        'yfinance', 'income',  'diluted_earnings_per_share'),
  ('shares_basic',       'sec',      'income',  'weighted_ave_basic_shares_os'),
  ('shares_basic',       'yfinance', 'income',  'weighted_average_basic_shares_outstanding'),
  ('shares_diluted',     'sec',      'income',  'weighted_ave_diluted_shares_os'),
  ('shares_diluted',     'yfinance', 'income',  'weighted_average_diluted_shares_outstanding'),
  ('total_assets',       'sec',      'balance', 'total_assets'),
  ('total_assets',       'yfinance', 'balance', 'total_assets'),
  ('total_liabilities',  'sec',      'balance', 'total_liabilities'),
  ('total_liabilities',  'yfinance', 'balance', 'total_liabilities_net_minority_interest'),
  ('total_equity',       'sec',      'balance', 'total_equity'),
  ('total_equity',       'yfinance', 'balance', 'common_stock_equity'),
  ('cash_and_equivalents','sec',     'balance', 'cash_and_equivalents'),
  ('cash_and_equivalents','yfinance','balance', 'cash_and_cash_equivalents'),
  ('long_term_debt',     'sec',      'balance', 'long_term_debt'),
  ('long_term_debt',     'yfinance', 'balance', 'long_term_debt'),
  ('short_term_debt',    'sec',      'balance', 'short_term_debt'),
  ('short_term_debt',    'yfinance', 'balance', 'current_debt_and_capital_lease_obligation'),
  ('operating_cash_flow','sec',      'cash',    'net_cash_from_operating_activities'),
  ('operating_cash_flow','yfinance', 'cash',    'operating_cash_flow'),
  ('capital_expenditure','sec',      'cash',    'purchase_of_plant_property_and_equipment'),
  ('capital_expenditure','yfinance', 'cash',    'capital_expenditure'),
  ('buyback',            'sec',      'cash',    'repurchase_of_common_equity'),
  ('buyback',            'yfinance', 'cash',    'repurchase_of_capital_stock'),
  ('stock_based_comp',   'sec',      'cash',    'stock_based_compensation'),
  ('stock_based_comp',   'yfinance', 'cash',    'stock_based_compensation'),
  ('dividends_paid',     'sec',      'cash',    'payment_of_dividends'),
  ('dividends_paid',     'yfinance', 'cash',    'cash_dividends_paid'),
  ('free_cash_flow',     'yfinance', 'cash',    'free_cash_flow')
on conflict (metric_code, source_code) do update set
  statement = excluded.statement, field = excluded.field;

-- ── grants + RLS ─────────────────────────────────────────────────────────────────────────────
-- Every `market` table gets an explicit policy, never grants alone. And `service_role` gets full
-- write on all three: `every-table-is-reachable.sql` exists because migration 42 granted two views
-- and forgot the table they read, and the resource failed in production with `permission denied`
-- after passing every functional check — the migration tests run as superuser and cannot see it.
grant select on market.metric, market.metric_source_field, market.security_metric
  to anon, authenticated, service_role;
grant insert, update, delete on market.metric, market.metric_source_field, market.security_metric
  to service_role;

alter table market.metric              enable row level security;
alter table market.metric_source_field enable row level security;
alter table market.security_metric     enable row level security;
do $$ begin
  create policy metric_public_read on market.metric for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy metric_source_field_public_read on market.metric_source_field for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy security_metric_public_read on market.security_metric for select using (true);
exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
