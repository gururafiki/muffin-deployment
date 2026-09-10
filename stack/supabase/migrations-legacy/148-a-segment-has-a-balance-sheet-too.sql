-- A SEGMENT HAS A BALANCE SHEET TOO, AND AN INSTANT IS NOT A FLOW.
--
-- `security-segments` read revenue and operating income out of each filing's instance and left
-- four more concepts on the floor. Measured on Amazon's 10-Q, the facts carrying a segment
-- dimension are: revenue (48), `SegmentExpenditureAdditionToLongLivedAssets` (20),
-- `CostsAndExpenses` (12), `OperatingIncomeLoss` (12), `Depreciation` (12), `Assets` (6).
-- Migration 146 took the capex. This takes the rest.
--
-- What it buys, verified live on Amazon:
--     AWS assets       194,295,000,000 at 2025-06-30
--     AWS depreciation   4,844,000,000 for the quarter
--     AWS capex         16,043,000,000 for the quarter
-- Beside AWS's 10,160,000,000 of quarterly operating income, that is return on segment assets and
-- a capex-to-depreciation ratio per business line — the two numbers that say whether a division is
-- harvesting or building, and neither is sold by any free provider.
--
-- ── WHY THIS NEEDED A SCHEMA CHANGE AND CAPEX DID NOT ─────────────────────────────────────────
--
-- `Assets` is an INSTANT: a stock measured AT a date, not a flow accumulated over one. The parser
-- rejected instants outright and `period_type` admitted only `annual` and `quarter`.
--
-- The consequence runs deeper than a check constraint. A partition is recognised by RECONCILING to
-- the filing's own consolidated figure — and **segment assets never reconcile**, because corporate
-- assets and eliminations sit outside the segments exactly as unallocated cost does for segment
-- profit. No instant bucket can ever reconcile on its own, so every one of them would be partition
-- 0 for ever and nothing could aggregate them.
--
-- So the split is now learned per (metric, period type, span) as before, and APPLIED per
-- (axis, period end): the same members listed in the same table, whether the number beside them is
-- a flow or a stock. An instant at a date where no duration bucket exists — a balance-sheet
-- comparative, typically — stays partition 0, which is the honest answer rather than a guess.
alter table market.security_segment drop constraint if exists security_segment_period_type_check;
alter table market.security_segment add constraint security_segment_period_type_check
  check (period_type in ('annual', 'quarter', 'instant'));

comment on column market.security_segment.period_type is
  'annual / quarter for flows measured over a period; `instant` for stocks measured at a date (segment assets). An instant''s partition is inherited from a duration bucket on the same axis and date, because segment assets never sum to consolidated assets and could otherwise never be placed.';

-- ── Two metrics the catalogue did not have ────────────────────────────────────────────────────
--
-- `is_flow` IS SET EXPLICITLY, not left to migration 104's `update`. That statement derives the
-- flag from `category` and runs BEFORE this file on every pass, so a row inserted here would carry
-- the `false` default until the NEXT deploy — and a flow that is not marked as one is silently
-- excluded from `derive_ttm`, which is a missing series rather than an error.
insert into market.metric (code, name, category, unit, is_derived, is_flow, sort_order, notes) values
  ('cost_of_revenue', 'Cost of revenue', 'income_statement', 'currency', false, true, 21,
   'The direct cost of what was sold. Beside revenue on the same segment axis it gives a gross margin per business line.'),
  ('depreciation',    'Depreciation',    'cash_flow',        'currency', false, true, 62,
   'Depreciation and amortisation. Beside capital expenditure on the same segment axis it says whether a division is building or harvesting.')
on conflict (code) do update
  set name = excluded.name, category = excluded.category, unit = excluded.unit,
      is_flow = excluded.is_flow, sort_order = excluded.sort_order, notes = excluded.notes;

-- These are also read by `security-xbrl` for UNDIMENSIONED facts, so the whole universe gains a
-- consolidated cost-of-revenue and depreciation series it did not have. That is a deliberate
-- ~8% growth of `security_metric` (3.29M rows) in exchange for gross margin and EBITDA becoming
-- computable — not an accident of adding a segment metric.
insert into market.xbrl_concept (metric_code, concept, priority, unit, taxonomy) values
  ('cost_of_revenue', 'CostOfGoodsAndServicesSold',            100, 'USD', 'us-gaap'),
  ('cost_of_revenue', 'CostOfRevenue',                          90, 'USD', 'us-gaap'),
  ('cost_of_revenue', 'CostOfSales',                           100, 'USD', 'ifrs-full'),
  ('depreciation',    'Depreciation',                          100, 'USD', 'us-gaap'),
  ('depreciation',    'DepreciationDepletionAndAmortization',   90, 'USD', 'us-gaap'),
  ('depreciation',    'DepreciationAndAmortisationExpense',    100, 'USD', 'ifrs-full')
on conflict (metric_code, concept) do update
  set priority = excluded.priority, unit = excluded.unit, taxonomy = excluded.taxonomy;

-- ── AND EACH PROVIDER'S SPELLING FOR THEM ─────────────────────────────────────────────────────
--
-- Caught by `tests/two-providers-do-not-share-a-vocabulary.sql` the moment the metrics were added,
-- which is the guard working: a metric with no field mapping is not an error, it is an empty
-- chart. `sec` and `yfinance` share 4 of 40 income-statement field names, so every spelling is a
-- row rather than a branch.
--
-- MEASURED against the live `security_statement.data` rather than guessed — the field lists are:
--   income, sec:      total_cost_of_revenue, operating_cost_of_revenue, depreciation_and_amortization
--   income, yfinance: cost_of_revenue, reconciled_cost_of_revenue, depreciation_income_statement
--   cash,   sec:      depreciation_and_amortization, depreciation_expense
--   cash,   yfinance: depreciation, depreciation_and_amortization
--
-- Note `cost_of_revenue` is the yfinance spelling AND this schema's metric code, which is a
-- coincidence worth not relying on: the `sec` spelling is `total_cost_of_revenue`, and reading the
-- metric code as if it were a field name is how a provider silently returns nothing.
insert into market.metric_source_field (metric_code, source_code, statement, field) values
  ('cost_of_revenue', 'sec',      'income', 'total_cost_of_revenue'),
  ('cost_of_revenue', 'yfinance', 'income', 'cost_of_revenue'),
  -- Depreciation is taken from the CASH FLOW statement, where both providers report it and the
  -- spellings happen to agree. The income-statement spellings differ wildly
  -- (`depreciation_and_amortization` against `depreciation_and_amortization_in_income_statement`)
  -- and are a subset of the cash-flow figure, so one statement is the right source rather than two.
  ('depreciation',    'sec',      'cash',   'depreciation_and_amortization'),
  ('depreciation',    'yfinance', 'cash',   'depreciation_and_amortization')
-- Keyed (metric_code, source_code): ONE field per metric per provider, with the statement as an
-- attribute rather than part of the key. So a metric reported on two statements has to pick one,
-- which is why depreciation is taken from the cash flow.
on conflict (metric_code, source_code) do update
  set statement = excluded.statement, field = excluded.field;

-- ── Serving ───────────────────────────────────────────────────────────────────────────────────
--
-- Widened so the new numbers are readable rather than merely stored — an unread view cannot be
-- wrong, and this schema has shipped correct data nothing consumed more than once.
--
-- Assets come from a SEPARATE lateral because they are an instant: the latest one at or before the
-- annual period end, rather than a row in the same pivot.
-- ── `security_segment_current` IS DEFINED ONCE, IN MIGRATION 157 ──────────────────────────────
-- It used to be defined here too. FIVE migrations (141, 148, 149, 150, 157) each carried a
-- `create view` for it with a different column list, and `create or replace view` can only APPEND
-- columns — so the earliest definer could never impose the latest one's shape and had to DROP,
-- taking its dependents with it. That is a real window on EVERY deploy, roughly sixteen files
-- wide, in which the view and the segment spine do not exist. Tolerable only while nothing
-- user-facing read them, which stopped being true when the stock page began drawing business
-- lines. The header above still records WHY the view carries what it carries; only the DDL moved.


-- `security_segment_current` is granted where it is defined, in migration 157.

notify pgrst, 'reload schema';
