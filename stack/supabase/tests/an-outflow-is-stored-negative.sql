-- AN OUTFLOW IS STORED NEGATIVE, WHOEVER STATED IT. Migration 20261108235000.
--
-- SEC company facts state capex, buybacks and dividends paid as positive payments; Yahoo and
-- openbb's `sec` rows state them negative. The metric layer stores them negative. Each rule gets a
-- row where the plausible wrong rule answers differently:
--   (a) company facts' payments turn negative: 100 -> -100 (no sign at all leaves +100);
--   (b) a filer that tagged a payment negative reads as the inflow it stated: -5 -> +5 (`-abs()`
--       would give -5);
--   (c) the computed quarters (`sec-xbrl-ytd`) turn too; Yahoo's and openbb's do not move;
--   (d) a metric that is not an outflow is untouched, and free cash flow is still OCF - |capex|;
--   (e) the fourth-quarter guard judges an outflow as the payments it records: quarters of -30, -30,
--       -50 against a year of -100 leave +10, which is a year and quarters that disagree, refused;
--   (f) a loss-making company's profitable fourth quarter is still derived: net income -10 x 3
--       against a year of -20 leaves +10 (a mirror for every metric would refuse it);
--   (g) an ordinary outflow fourth quarter is derived: -120 less -90 is -30.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('yfinance','yfinance',100), ('sec','SEC',250), ('sec-xbrl','SEC company facts',275)
on conflict (code) do nothing;
insert into market.data_source (code, name, priority, computed_from) values
  ('sec-xbrl-ytd','SEC company facts, computed quarters',45,'sec-xbrl')
on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZF','Testfiscalia','ZF',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009401', 'T94 Payments', 'equity', 'ZF'),
  ('00000000-0000-0000-0000-000000009402', 'T94 Fourth Quarters', 'equity', 'ZF')
on conflict (security_id) do nothing;

insert into market.security_statement
  (security_id, statement, period_ending, period_type, currency, data, source_code, as_of, derived_at)
values
  ('00000000-0000-0000-0000-000000009401', 'cash', date '2024-12-31', 'annual', 'USD',
   '{"operating_cash_flow": 500, "capital_expenditure": 100, "buyback": 30, "dividends_paid": 20}'::jsonb,
   'sec-xbrl', now(), null),
  ('00000000-0000-0000-0000-000000009401', 'cash', date '2023-12-31', 'annual', 'USD',
   '{"capital_expenditure": -5}'::jsonb, 'sec-xbrl', now(), null),
  ('00000000-0000-0000-0000-000000009401', 'cash', date '2024-06-30', 'quarter', 'USD',
   '{"capital_expenditure": 40}'::jsonb, 'sec-xbrl-ytd', now(), null),
  ('00000000-0000-0000-0000-000000009401', 'cash', date '2022-12-31', 'annual', 'USD',
   '{"operating_cash_flow": 300, "capital_expenditure": -80}'::jsonb, 'yfinance', now(), null),
  ('00000000-0000-0000-0000-000000009401', 'cash', date '2021-12-31', 'annual', 'USD',
   '{"purchase_of_plant_property_and_equipment": -70}'::jsonb, 'sec', now(), null);

select market.derive_security_metrics(null);

-- The fourth-quarter guard, on metrics as the derivation now writes them.
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
values
  -- (e) -100 against -30, -30, -50: a remainder of +10
  ('00000000-0000-0000-0000-000000009402', 'capital_expenditure', 'annual',  date '2025-12-31', -100, 'USD', 'sec-xbrl', now()),
  ('00000000-0000-0000-0000-000000009402', 'capital_expenditure', 'quarter', date '2025-03-31',  -30, 'USD', 'sec-xbrl', now()),
  ('00000000-0000-0000-0000-000000009402', 'capital_expenditure', 'quarter', date '2025-06-30',  -30, 'USD', 'sec-xbrl', now()),
  ('00000000-0000-0000-0000-000000009402', 'capital_expenditure', 'quarter', date '2025-09-30',  -50, 'USD', 'sec-xbrl', now()),
  -- (g) -120 against -30 x 3: a fourth quarter of -30
  ('00000000-0000-0000-0000-000000009402', 'capital_expenditure', 'annual',  date '2024-12-31', -120, 'USD', 'sec-xbrl', now()),
  ('00000000-0000-0000-0000-000000009402', 'capital_expenditure', 'quarter', date '2024-03-31',  -30, 'USD', 'sec-xbrl', now()),
  ('00000000-0000-0000-0000-000000009402', 'capital_expenditure', 'quarter', date '2024-06-30',  -30, 'USD', 'sec-xbrl', now()),
  ('00000000-0000-0000-0000-000000009402', 'capital_expenditure', 'quarter', date '2024-09-30',  -30, 'USD', 'sec-xbrl', now()),
  -- (f) net income -20 against -10 x 3: a profitable fourth quarter of +10
  ('00000000-0000-0000-0000-000000009402', 'net_income', 'annual',  date '2025-12-31', -20, 'USD', 'sec-xbrl', now()),
  ('00000000-0000-0000-0000-000000009402', 'net_income', 'quarter', date '2025-03-31', -10, 'USD', 'sec-xbrl', now()),
  ('00000000-0000-0000-0000-000000009402', 'net_income', 'quarter', date '2025-06-30', -10, 'USD', 'sec-xbrl', now()),
  ('00000000-0000-0000-0000-000000009402', 'net_income', 'quarter', date '2025-09-30', -10, 'USD', 'sec-xbrl', now());

select market.derive_ttm('00000000-0000-0000-0000-000000009402'::uuid);

do $$
declare
  pay constant uuid := '00000000-0000-0000-0000-000000009401';
  q4s constant uuid := '00000000-0000-0000-0000-000000009402';
  v numeric;
  n int;
begin
  -- THE FLOOR: the derivation produced the rows the assertions read.
  select count(*) into n from market.security_metric where security_id = pay;
  if n < 10 then
    raise exception 'expected at least 10 metrics derived for the payments fixture, got %', n;
  end if;

  select value into v from market.security_metric
   where security_id = pay and metric_code = 'capital_expenditure' and period_type = 'annual'
     and as_of = '2024-12-31';
  if v is distinct from -100 then
    raise exception '(a) company facts'' capex of 100 must be stored as -100; got %', v;
  end if;
  select value into v from market.security_metric
   where security_id = pay and metric_code = 'buyback' and as_of = '2024-12-31';
  if v is distinct from -30 then
    raise exception '(a) company facts'' buyback of 30 must be stored as -30; got %', v;
  end if;
  select value into v from market.security_metric
   where security_id = pay and metric_code = 'dividends_paid' and as_of = '2024-12-31';
  if v is distinct from -20 then
    raise exception '(a) company facts'' dividends paid of 20 must be stored as -20; got %', v;
  end if;

  select value into v from market.security_metric
   where security_id = pay and metric_code = 'capital_expenditure' and as_of = '2023-12-31';
  if v is distinct from 5 then
    raise exception '(b) a payment tagged -5 is the inflow it states, +5 (not -abs); got %', v;
  end if;

  select value into v from market.security_metric
   where security_id = pay and metric_code = 'capital_expenditure' and period_type = 'quarter'
     and as_of = '2024-06-30';
  if v is distinct from -40 then
    raise exception '(c) a computed quarter''s capex of 40 must be stored as -40; got %', v;
  end if;
  select value into v from market.security_metric
   where security_id = pay and metric_code = 'capital_expenditure' and as_of = '2022-12-31';
  if v is distinct from -80 then
    raise exception '(c) Yahoo''s capex of -80 must not move; got %', v;
  end if;
  select value into v from market.security_metric
   where security_id = pay and metric_code = 'capital_expenditure' and as_of = '2021-12-31';
  if v is distinct from -70 then
    raise exception '(c) openbb''s `sec` capex of -70 must not move; got %', v;
  end if;

  select value into v from market.security_metric
   where security_id = pay and metric_code = 'operating_cash_flow' and as_of = '2024-12-31';
  if v is distinct from 500 then
    raise exception '(d) operating cash flow is not an outflow and must stay 500; got %', v;
  end if;
  select value into v from market.security_metric
   where security_id = pay and metric_code = 'free_cash_flow' and as_of = '2024-12-31';
  if v is distinct from 400 then
    raise exception '(d) free cash flow is 500 - |-100| = 400; got %', v;
  end if;
  select value into v from market.security_metric
   where security_id = pay and metric_code = 'free_cash_flow' and as_of = '2022-12-31';
  if v is distinct from 220 then
    raise exception '(d) free cash flow is 300 - |-80| = 220; got %', v;
  end if;

  select count(*) into n from market.security_metric
   where security_id = q4s and metric_code = 'capital_expenditure' and source_code = 'derived-q4'
     and as_of = '2025-12-31';
  if n <> 0 then
    raise exception '(e) an outflow year of -100 against quarters of -110 disagrees; no fourth '
                    'quarter may be derived, got %', n;
  end if;

  select value into v from market.security_metric
   where security_id = q4s and metric_code = 'net_income' and source_code = 'derived-q4'
     and as_of = '2025-12-31';
  if v is distinct from 10 then
    raise exception '(f) a loss-making year''s profitable fourth quarter (+10) must be derived; got %', v;
  end if;

  select value into v from market.security_metric
   where security_id = q4s and metric_code = 'capital_expenditure' and source_code = 'derived-q4'
     and as_of = '2024-12-31';
  if v is distinct from -30 then
    raise exception '(g) an outflow fourth quarter of -120 less -90 is -30; got %', v;
  end if;

  raise notice 'ok  an outflow is stored negative whoever stated it; its fourth quarter is guarded as before';
end $$;

rollback;
