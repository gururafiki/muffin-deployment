-- COMPANY FACTS READ THEIR OWN CONCEPTS. Phase 5 step 4 of the umbrella's
-- docs/specs/2026-10-24-sec-family.md (decision 14, the user, 2026-10-27).
--
-- The Dagster company facts reader resolves each statement line through `market.xbrl_concept`,
-- which the edge's `security-xbrl` and segments parser also read. That table cannot say us-gaap's
-- `Assets`, `Liabilities` or `GrossProfit`: its key is `(metric_code, concept)` with no taxonomy, and
-- ifrs-full rows of the same names already hold those keys, so the us-gaap rows would collide. The
-- edge also kept it narrow on purpose: anything added there is written by `security-xbrl` for the
-- whole universe and read by the segments parser.
--
-- Measured 2026-10-27: the edge's `sec-xbrl` metrics hold total assets for 311 securities (almost
-- all IFRS filers), and Apple's 18 years of total assets, total liabilities, gross profit and R&D
-- exist only in the openbb `sec` rows that decision 12 deletes after parity. In the 19 filers whose
-- company facts were captured, every US filer states us-gaap `Assets`, and every IFRS filer states
-- `Goodwill` and the share-count, buyback and share-based-pay lines `xbrl_concept` lacks.
--
-- `market.xbrl_fact_concept` holds those ADDITIONS, keyed with the taxonomy. Only the Dagster reader
-- reads it, together with `xbrl_concept`; the edge's readers keep `xbrl_concept` unchanged until
-- they retire (step 9; the segments parser in Phase 6), when the two can merge. Each value was
-- checked against a filing: SAP's 2025 goodwill EUR 29,014,000,000, 1,166,000,000 basic and
-- 1,175,000,000 diluted shares, a EUR 1,937,000,000 buyback, EUR 1,695,000,000 share-based pay.
--
-- LEFT OUT ON PURPOSE: ifrs-full `NoncurrentAssets` is TOTAL non-current assets (SAP EUR
-- 50,106,000,000), while us-gaap's `NoncurrentAssets`, already mapped to `long_lived_assets`, means
-- long-lived assets. One name, two numbers. And ifrs-full `SellingGeneralAndAdministrativeExpense`,
-- which none of the six IFRS filers states.
--
-- The worker only READS it, so `ingest_rw`'s default DML on `market` is revoked.
--
-- `metric_source_field` gains a `sec-xbrl` row for every metric either table can produce, with the
-- metric code as its field (the reader writes a statement's data keyed by metric code) and the
-- statement the metric's category puts it in. It is what `derive_security_metrics` reads a
-- `sec-xbrl` statement through, and what the reader takes its lines from, so the two cannot place a
-- line in different statements.
--
-- Guard: stack/supabase/tests/company-facts-read-their-own-concepts.sql.

create table if not exists market.xbrl_fact_concept (
  metric_code text not null references market.metric (code) on delete cascade,
  taxonomy    text not null,
  concept     text not null,
  priority    integer not null default 100,
  -- A KIND, as in `xbrl_concept.unit`: `USD` is whichever currency the filer reports in.
  unit        text not null,
  primary key (metric_code, taxonomy, concept)
);
comment on table market.xbrl_fact_concept is
  'Concepts the company facts reader reads besides market.xbrl_concept, keyed with the taxonomy. '
  'Read only by the Dagster SEC lane; the edge''s readers read xbrl_concept alone.';

insert into market.xbrl_fact_concept (metric_code, taxonomy, concept, priority, unit) values
  ('total_assets',      'us-gaap',   'Assets',                                  100, 'USD'),
  ('total_liabilities', 'us-gaap',   'Liabilities',                             100, 'USD'),
  ('gross_profit',      'us-gaap',   'GrossProfit',                             100, 'USD'),
  ('rd_expense',        'us-gaap',   'ResearchAndDevelopmentExpense',           100, 'USD'),
  ('goodwill',          'ifrs-full', 'Goodwill',                                100, 'USD'),
  ('shares_basic',      'ifrs-full', 'WeightedAverageShares',                   100, 'shares'),
  ('shares_diluted',    'ifrs-full', 'AdjustedWeightedAverageShares',           100, 'shares'),
  ('buyback',           'ifrs-full', 'PaymentsToAcquireOrRedeemEntitysShares',  100, 'USD'),
  ('stock_based_comp',  'ifrs-full', 'AdjustmentsForSharebasedPayments',        100, 'USD')
on conflict (metric_code, taxonomy, concept) do nothing;

grant select on market.xbrl_fact_concept to anon, authenticated, ingest_rw;
grant select, insert, update, delete on market.xbrl_fact_concept to service_role;
revoke insert, update, delete on market.xbrl_fact_concept from ingest_rw;
alter table market.xbrl_fact_concept enable row level security;
drop policy if exists xbrl_fact_concept_public_read on market.xbrl_fact_concept;
create policy xbrl_fact_concept_public_read on market.xbrl_fact_concept for select using (true);

insert into market.metric_source_field (metric_code, source_code, statement, field)
select m.code,
       'sec-xbrl',
       case m.category
         when 'income_statement' then 'income'
         when 'balance_sheet'    then 'balance'
         when 'cash_flow'        then 'cash'
         -- Share counts are read beside EPS, as `sec` and `yfinance` place them.
         when 'share'            then 'income'
       end,
       m.code
  from market.metric m
 where m.code in (select metric_code from market.xbrl_concept
                  union
                  select metric_code from market.xbrl_fact_concept)
on conflict (metric_code, source_code) do nothing;
