-- HALF THE FILERS REPORT IN IFRS, AND THE RESOLVER ONLY READ US-GAAP.
--
-- The first real run of `security-xbrl` returned `written: 11104, filers: 20, noFacts: 10`. Every
-- one of the ten was a FOREIGN PRIVATE ISSUER: AB InBev (BE), Ryanair and AIB (IE), Equinor (NO),
-- Santander (ES), Novo Nordisk (DK), TSMC (TW), BHP (AU), Credicorp (BM), Nokia (FI). They file
-- 20-F under IFRS, and `companyfacts` puts those under `ifrs-full` — measured, AB InBev's
-- taxonomies are exactly `['dei', 'ifrs-full']`, with no `us-gaap` node at all.
--
-- Reading one taxonomy therefore marked ten perfectly good filers as having no facts, for 30 days,
-- with no error. The resource reported success.
--
-- ── THE CONCEPT NAMES ARE DIFFERENT, AND WERE MEASURED ──────────────────────────────────────
--
-- Probed across AB InBev, Novo Nordisk, TSMC, Nokia and BHP — 14 or 15 of 15 metrics hit for every
-- one of them:
--
--   revenue              us-gaap RevenueFromContractWithCustomer...  ifrs-full Revenue
--   net_income                   NetIncomeLoss                                 ProfitLoss
--   operating_income             OperatingIncomeLoss                           ProfitLossFromOperatingActivities
--   pretax_income                IncomeLossFromContinuingOper...               ProfitLossBeforeTax
--   total_equity                 StockholdersEquity                            Equity
--   operating_cash_flow          NetCashProvidedByUsedInOper...                CashFlowsFromUsedInOperatingActivities
--   eps_diluted                  EarningsPerShareDiluted                       DilutedEarningsLossPerShare
--
-- ── AND THE UNIT IS THE REPORTING CURRENCY, WHICH IS THE POINT ──────────────────────────────
--
-- A US filer's facts live under a `USD` unit key. An IFRS filer's live under THEIR currency: Novo
-- Nordisk `DKK`, Nokia `EUR`, TSMC `TWD` **and** `USD` (a convenience translation alongside the
-- primary). So the unit key is not a constant to match — it IS the reporting currency, arriving
-- free and per company. `xbrl_concept.unit` is therefore read as a KIND rather than a literal:
-- 'USD' means "whichever currency this filer reports in", 'USD/shares' means per-share in that
-- currency, and 'shares' means a count with no currency at all.
--
-- Where a filer publishes several currencies the one with the MOST data points wins — the primary
-- reporting currency has the full history and a convenience translation has a few years. Picking
-- USD instead would relabel Novo Nordisk's kroner as dollars, which is the Alibaba bug again.

alter table market.xbrl_concept
  add column if not exists taxonomy text not null default 'us-gaap';

comment on column market.xbrl_concept.taxonomy is
  'The companyfacts taxonomy node: `us-gaap` for domestic filers, `ifrs-full` for foreign private issuers filing 20-F. Reading only one marked 10 of 20 filers as having no facts — AB InBev''s companyfacts has no us-gaap node at all.';
comment on column market.xbrl_concept.unit is
  'A KIND, not a literal. `USD` means "whichever currency this filer reports in" — Novo Nordisk''s facts are under a DKK unit key and Nokia''s under EUR. `USD/shares` is per-share in that currency; `shares` is a count with no currency.';

insert into market.xbrl_concept (metric_code, concept, priority, unit, taxonomy) values
  ('revenue',             'Revenue',                                 100, 'USD',        'ifrs-full'),
  ('revenue',             'RevenueFromContractsWithCustomers',        90, 'USD',        'ifrs-full'),
  ('net_income',          'ProfitLoss',                              100, 'USD',        'ifrs-full'),
  ('net_income',          'ProfitLossAttributableToOwnersOfParent',   90, 'USD',        'ifrs-full'),
  ('gross_profit',        'GrossProfit',                             100, 'USD',        'ifrs-full'),
  ('operating_income',    'ProfitLossFromOperatingActivities',       100, 'USD',        'ifrs-full'),
  ('pretax_income',       'ProfitLossBeforeTax',                     100, 'USD',        'ifrs-full'),
  ('income_tax',          'IncomeTaxExpenseContinuingOperations',    100, 'USD',        'ifrs-full'),
  ('rd_expense',          'ResearchAndDevelopmentExpense',           100, 'USD',        'ifrs-full'),
  ('total_assets',        'Assets',                                  100, 'USD',        'ifrs-full'),
  ('total_liabilities',   'Liabilities',                             100, 'USD',        'ifrs-full'),
  ('total_equity',        'Equity',                                  100, 'USD',        'ifrs-full'),
  ('total_equity',        'EquityAttributableToOwnersOfParent',       90, 'USD',        'ifrs-full'),
  ('cash_and_equivalents','CashAndCashEquivalents',                  100, 'USD',        'ifrs-full'),
  ('long_term_debt',      'NoncurrentPortionOfNoncurrentBorrowings', 100, 'USD',        'ifrs-full'),
  ('short_term_debt',     'CurrentPortionOfNoncurrentBorrowings',    100, 'USD',        'ifrs-full'),
  ('operating_cash_flow', 'CashFlowsFromUsedInOperatingActivities',  100, 'USD',        'ifrs-full'),
  ('capital_expenditure', 'PurchaseOfPropertyPlantAndEquipmentClassifiedAsInvestingActivities', 100, 'USD', 'ifrs-full'),
  ('dividends_paid',      'DividendsPaidClassifiedAsFinancingActivities', 100, 'USD',   'ifrs-full'),
  ('dividends_paid',      'DividendsPaid',                            90, 'USD',        'ifrs-full'),
  ('eps_basic',           'BasicEarningsLossPerShare',               100, 'USD/shares', 'ifrs-full'),
  ('eps_diluted',         'DilutedEarningsLossPerShare',             100, 'USD/shares', 'ifrs-full')
on conflict (metric_code, concept) do update set
  priority = excluded.priority, unit = excluded.unit, taxonomy = excluded.taxonomy;

-- THE TEN FILERS MARKED BY THE US-GAAP-ONLY RESOLVER ARE CLEARED. They were never asked the right
-- question, and a 30-day negative cache would keep the answer wrong for a month. A repair runs on
-- every deploy, so it is behind `one_shot` — clearing the flag unconditionally would defeat the
-- cache for filers that genuinely have nothing.
do $$
begin
  if not exists (select 1 from market.one_shot where key = 'clear-ifrs-xbrl-marks') then
    update market.security set xbrl_missing_at = null, xbrl_fetched_at = null
     where xbrl_missing_at is not null;
    insert into market.one_shot (key) values ('clear-ifrs-xbrl-marks');
  end if;
end $$;

notify pgrst, 'reload schema';
