-- A RETRACTED STATEMENT TAKES ITS METRICS WITH IT, AND THE NEXT SOURCE FILLS THE GAP.
-- Migration 20261108150000.
--
-- WHY THIS EXISTS. The derivation only adds or overwrites. On 2026-11-08 the SEC grid re-parse
-- retracted Magnera's 2022-12-31 and Republic Airways' 2024-09-30 statements (their calendars had
-- been rebuilt), and the revenue metrics derived from them stayed, still labelled as fiscal years:
-- 273 and 274 days from the next year, which `check_one_period_one_point` reads as one year reported
-- twice. 1,286 labelled metrics had outlived their statements.
--
-- Three securities, so the candidate rules disagree:
--   T91  SEC and yfinance both state 2022; SEC's statements are retracted. SEC's revenue and the
--        free cash flow computed from SEC's cash flow must go, and yfinance's revenue take the key.
--   T92  the same, but yfinance's statement is the one retracted. SEC's revenue, which won the key,
--        must stay: a rule that clears every metric at the key fails here.
--   T93  SEC's income statement is retracted and its cash flow stays. Free cash flow must stay: a
--        rule that drops the computed metrics whatever was removed fails here.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('yfinance', 'yfinance', 100), ('sec-xbrl', 'SEC XBRL company facts', 275), ('derived', 'derived', 50)
on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD', 'US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZM', 'Testland', 'ZM', false)
  on conflict (iso2) do nothing;
insert into market.metric_source_field (metric_code, source_code, statement, field) values
  ('revenue',             'sec-xbrl', 'income', 'revenue'),
  ('operating_cash_flow', 'sec-xbrl', 'cash',   'operating_cash_flow'),
  ('capital_expenditure', 'sec-xbrl', 'cash',   'capital_expenditure'),
  ('revenue',             'yfinance', 'income', 'total_revenue')
on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009101', 'T91 SEC retracted',      'equity', 'ZM'),
  ('00000000-0000-0000-0000-000000009102', 'T92 yfinance retracted', 'equity', 'ZM'),
  ('00000000-0000-0000-0000-000000009103', 'T93 income retracted',   'equity', 'ZM')
on conflict (security_id) do nothing;

insert into market.security_statement
  (security_id, statement, period_ending, period_type, currency, data, source_code, fiscal_year, fiscal_period) values
  ('00000000-0000-0000-0000-000000009101', 'income', date '2022-12-31', 'annual', 'USD',
   '{"revenue": 1500}', 'sec-xbrl', 2022, 'FY'),
  ('00000000-0000-0000-0000-000000009101', 'cash',   date '2022-12-31', 'annual', 'USD',
   '{"operating_cash_flow": 300, "capital_expenditure": 50}', 'sec-xbrl', 2022, 'FY'),
  ('00000000-0000-0000-0000-000000009101', 'income', date '2022-12-31', 'annual', 'USD',
   '{"total_revenue": 1400}', 'yfinance', null, null),
  ('00000000-0000-0000-0000-000000009102', 'income', date '2022-12-31', 'annual', 'USD',
   '{"revenue": 2000}', 'sec-xbrl', 2022, 'FY'),
  ('00000000-0000-0000-0000-000000009102', 'income', date '2022-12-31', 'annual', 'USD',
   '{"total_revenue": 1900}', 'yfinance', null, null),
  ('00000000-0000-0000-0000-000000009103', 'income', date '2022-12-31', 'annual', 'USD',
   '{"revenue": 3000}', 'sec-xbrl', 2022, 'FY'),
  ('00000000-0000-0000-0000-000000009103', 'cash',   date '2022-12-31', 'annual', 'USD',
   '{"operating_cash_flow": 700, "capital_expenditure": 200}', 'sec-xbrl', 2022, 'FY');

select market.derive_security_metrics(null);
insert into market.ttm_derivation (security_id, derived_at) values
  ('00000000-0000-0000-0000-000000009101', now()),
  ('00000000-0000-0000-0000-000000009103', now())
on conflict (security_id) do update set derived_at = excluded.derived_at;

-- The fixture derived as intended, or every assertion below proves nothing.
do $$
declare v numeric; sc text;
begin
  select value, source_code into v, sc from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009101' and metric_code = 'revenue'
     and period_type = 'annual' and as_of = date '2022-12-31';
  if v is distinct from 1500 or sc is distinct from 'sec-xbrl' then
    raise exception 'fixture: T91 revenue is % from %, not 1500 from sec-xbrl', v, sc;
  end if;
  select value into v from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009103' and metric_code = 'free_cash_flow'
     and period_type = 'annual' and as_of = date '2022-12-31' and source_code = 'derived';
  if v is distinct from 500 then
    raise exception 'fixture: T93 free cash flow is %, not 700 - 200', v;
  end if;
end $$;

-- The retractions, as the SEC filer lane's `retract_unproduced` makes them.
delete from market.security_statement
 where security_id = '00000000-0000-0000-0000-000000009101' and source_code = 'sec-xbrl';
delete from market.security_statement
 where security_id = '00000000-0000-0000-0000-000000009102' and source_code = 'yfinance';
delete from market.security_statement
 where security_id = '00000000-0000-0000-0000-000000009103' and source_code = 'sec-xbrl'
   and statement = 'income';

do $$
declare n integer; v numeric; sc text; fy smallint;
begin
  -- T91, before any re-derivation: SEC's metrics are gone with their statements.
  select count(*) into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009101' and source_code in ('sec-xbrl', 'derived');
  if n <> 0 then
    raise exception 'T91 still holds % metric(s) from statements that were retracted: the derivation '
                    'only adds or overwrites, so a metric outlives its statement with its old label '
                    '(Magnera and Republic Airways, 2026-11-08)', n;
  end if;
  select count(*) into n from market.security_statement
   where security_id = '00000000-0000-0000-0000-000000009101' and source_code = 'yfinance'
     and derived_at is null;
  if n <> 1 then
    raise exception 'T91''s yfinance statement was not re-queued: nothing would fill the key';
  end if;
  if exists (select 1 from market.ttm_derivation
              where security_id = '00000000-0000-0000-0000-000000009101') then
    raise exception 'T91''s TTM was not re-queued: pending_ttm waits for a newer input, and a deletion '
                    'is not one, so its TTM would keep the retracted figures';
  end if;

  -- T92: SEC's revenue won the key and its statement stays, so it stays.
  select value, source_code into v, sc from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009102' and metric_code = 'revenue'
     and period_type = 'annual' and as_of = date '2022-12-31';
  if v is distinct from 2000 or sc is distinct from 'sec-xbrl' then
    raise exception 'retracting T92''s yfinance statement left revenue % from %: a metric another source '
                    'won must not go with a statement that lost the key', v, sc;
  end if;

  -- T93: its cash flow stays, so free cash flow stays.
  select value into v from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009103' and metric_code = 'free_cash_flow'
     and period_type = 'annual' and as_of = date '2022-12-31';
  if v is distinct from 500 then
    raise exception 'retracting T93''s income statement left free cash flow %: it is computed from the '
                    'cash flow, which was not retracted', v;
  end if;
  select count(*) into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009103' and metric_code = 'revenue';
  if n <> 0 then
    raise exception 'T93''s revenue outlived its retracted income statement';
  end if;
end $$;

select market.derive_security_metrics(null);

do $$
declare v numeric; sc text; fy smallint;
begin
  -- T91 after re-derivation: the next source holds the key, unlabelled as its statement is.
  select value, source_code, fiscal_year into v, sc, fy from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009101' and metric_code = 'revenue'
     and period_type = 'annual' and as_of = date '2022-12-31';
  if v is distinct from 1400 or sc is distinct from 'yfinance' or fy is not null then
    raise exception 'after re-derivation T91''s revenue is % from % labelled %, not yfinance''s 1400 '
                    'unlabelled', v, sc, fy;
  end if;
  raise notice 'ok  a retracted statement takes its metrics with it, the next source fills the key, '
               'and a metric another source won or a computation whose inputs stayed is untouched';
end $$;

rollback;
