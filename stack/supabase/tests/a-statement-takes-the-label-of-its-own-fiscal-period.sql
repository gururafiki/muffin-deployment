-- A STATEMENT TAKES THE LABEL OF ITS OWN FISCAL PERIOD, AND ITS METRICS CARRY IT.
--
-- `market.label_fiscal_periods` labels a statement row from the company's CANONICAL fiscal periods
-- (migration 20261025100100). Each rule it applies is given a fixture row where the wrong rule
-- picks a different period:
--   - CLASS: a quarter ending on the year end is Q4, not FY, though FY's end is the nearer; a half
--     is H1, not Q2, though Q2's end is the nearer;
--   - CANONICAL: an annual row takes the canonical FY2024 (6 days away), not the superseded
--     regime's FY2025 (1 day away);
--   - WINDOW: 11 days from the nearest period is no label;
--   - RETRACTION: a label no period supports any more is removed;
--   - SCOPE: a security not asked about is untouched;
--   - `FY`, the retired spelling of `annual`, is labelled as annual.
-- Then: only changed rows are written (a second call writes none), a new label re-queues the row,
-- the derivation copies labels into metrics (free cash flow included) and does not rewrite an
-- unchanged metric, and `derive_ttm` labels a fiscal Q4 and a TTM from the year and the last
-- quarter.
--
-- Not covered here: `derive_security_metrics` marking `derived_at` by provider. The current key
-- admits one provider per period, so no fixture can tell the two markings apart until step 2b.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('yfinance','yfinance',100), ('sec-submissions','SEC submissions',255)
on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZF','Testfiscalia','ZF',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009201', 'T92 Changed Its Year End', 'equity', 'ZF'),
  ('00000000-0000-0000-0000-000000009202', 'T92 Not Asked About', 'equity', 'ZF'),
  ('00000000-0000-0000-0000-000000009203', 'T92 Derived Quarters', 'equity', 'ZF')
on conflict (security_id) do nothing;

-- 9201: an October year end (regime 1) changed to September (regime 2). Regime 2 is canonical.
insert into market.fiscal_calendar
  (security_id, regime, source_code, year_end_month, year_end_day, is_52_53_week, week_end_isodow,
   first_year_end, last_year_end, change_kind) values
  ('00000000-0000-0000-0000-000000009201', 1, 'sec-submissions', 10, 31, false, null,
   date '2021-10-31', date '2024-10-31', 'initial'),
  ('00000000-0000-0000-0000-000000009201', 2, 'sec-submissions', 9, 30, false, null,
   date '2024-09-30', null, 'year_end_change'),
  ('00000000-0000-0000-0000-000000009202', 1, 'sec-submissions', 12, 31, false, null,
   date '2020-12-31', null, 'initial');

insert into market.fiscal_period
  (security_id, regime, fiscal_year, fiscal_period, period_start, period_end, is_canonical,
   is_observed, source_code) values
  ('00000000-0000-0000-0000-000000009201', 2, 2024, 'FY', date '2023-10-01', date '2024-09-30', true,  true, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009201', 2, 2024, 'Q1', date '2023-10-01', date '2023-12-31', true,  true, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009201', 2, 2024, 'Q2', date '2024-01-01', date '2024-03-31', true,  true, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009201', 2, 2024, 'H1', date '2023-10-01', date '2024-04-03', true,  false, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009201', 2, 2024, 'Q3', date '2024-04-01', date '2024-06-30', true,  true, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009201', 2, 2024, 'Q4', date '2024-07-01', date '2024-09-28', true,  true, 'sec-submissions'),
  -- The superseded regime's year, one day from row (b) and labelled 2025: the wrong answer.
  ('00000000-0000-0000-0000-000000009201', 1, 2025, 'FY', date '2023-11-01', date '2024-10-05', false, true, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009202', 1, 2024, 'FY', date '2024-01-01', date '2024-12-31', true,  true, 'sec-submissions');

insert into market.security_statement
  (security_id, statement, period_ending, period_type, currency, data, source_code, as_of,
   derived_at, fiscal_year, fiscal_period) values
  -- (a) a quarter on the year end: Q4, though FY ends nearer
  ('00000000-0000-0000-0000-000000009201', 'income',  date '2024-09-30', 'quarter', 'USD', '{"total_revenue": 100}'::jsonb, 'yfinance', now() - interval '7 hours', now(), null, null),
  -- (a2) the same quarter's cash flow, for free cash flow
  ('00000000-0000-0000-0000-000000009201', 'cash',    date '2024-09-30', 'quarter', 'USD', '{"operating_cash_flow": 50, "capital_expenditure": -10}'::jsonb, 'yfinance', now() - interval '6 hours', now(), null, null),
  -- (b) a year: the canonical FY2024, not the superseded FY2025 a day away
  ('00000000-0000-0000-0000-000000009201', 'income',  date '2024-10-06', 'annual',  'USD', '{"total_revenue": 400}'::jsonb, 'yfinance', now() - interval '5 hours', now(), null, null),
  -- (c) a half: H1, though Q2 ends nearer
  ('00000000-0000-0000-0000-000000009201', 'income',  date '2024-03-31', 'half',    'USD', '{"total_revenue": 200}'::jsonb, 'yfinance', now() - interval '4 hours', now(), null, null),
  -- (d) a quarter: Q2
  ('00000000-0000-0000-0000-000000009201', 'income',  date '2024-03-31', 'quarter', 'USD', '{"total_revenue": 100}'::jsonb, 'yfinance', now() - interval '3 hours', now(), null, null),
  -- (e) eleven days from Q1's end: no label
  ('00000000-0000-0000-0000-000000009201', 'income',  date '2023-12-20', 'quarter', 'USD', '{"total_revenue": 100}'::jsonb, 'yfinance', now() - interval '2 hours', now(), null, null),
  -- (f) labelled once, and no period supports it now
  ('00000000-0000-0000-0000-000000009201', 'income',  date '2022-06-30', 'quarter', 'USD', '{"total_revenue": 1}'::jsonb,   'yfinance', now() - interval '1 hour',  now(), 2022, 'Q3'),
  -- (g) the retired `FY` spelling of annual
  ('00000000-0000-0000-0000-000000009201', 'balance', date '2024-09-30', 'FY',      'USD', '{}'::jsonb, 'yfinance', now() - interval '1 hour', now(), null, null),
  -- out of scope
  ('00000000-0000-0000-0000-000000009202', 'income',  date '2024-12-31', 'annual',  'USD', '{"total_revenue": 9}'::jsonb, 'yfinance', now() - interval '1 hour', now(), null, null);

-- The metric (f) once produced, carrying the label that is about to be retracted.
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at,
   fiscal_year, fiscal_period) values
  ('00000000-0000-0000-0000-000000009201', 'revenue', 'quarter', date '2022-06-30', 1, 'USD',
   'yfinance', now() - interval '1 day', 2022, 'Q3');

do $$
declare n integer;
begin
  n := market.label_fiscal_periods(array['00000000-0000-0000-0000-000000009201'::uuid]);
  if n <> 7 then
    raise exception 'label_fiscal_periods changed % row(s), expected 7 (six labelled, one retracted)', n;
  end if;
end $$;

do $$
declare
  r record;
  want record;
begin
  for want in
    select * from (values
      ('income',  date '2024-09-30', 'quarter', 2024::smallint, 'Q4', 'a quarter on the year end must be Q4, not FY: the class decides, then the distance'),
      ('cash',    date '2024-09-30', 'quarter', 2024::smallint, 'Q4', 'the cash flow of that quarter must be Q4'),
      ('income',  date '2024-10-06', 'annual',  2024::smallint, 'FY', 'a year must take the CANONICAL FY2024, not the superseded FY2025 nearer to it'),
      ('income',  date '2024-03-31', 'half',    2024::smallint, 'H1', 'a half must be H1, not Q2'),
      ('income',  date '2024-03-31', 'quarter', 2024::smallint, 'Q2', 'a quarter ending with Q2 must be Q2'),
      ('income',  date '2023-12-20', 'quarter', null::smallint, null, 'eleven days from the nearest period must be no label'),
      ('income',  date '2022-06-30', 'quarter', null::smallint, null, 'a label no period supports must be retracted'),
      ('balance', date '2024-09-30', 'FY',      2024::smallint, 'FY', 'the retired FY spelling must be labelled as annual')
    ) as t(statement, period_ending, period_type, fiscal_year, fiscal_period, why)
  loop
    select st.fiscal_year, st.fiscal_period into r
      from market.security_statement st
     where st.security_id = '00000000-0000-0000-0000-000000009201'
       and st.statement = want.statement and st.period_ending = want.period_ending
       and st.period_type = want.period_type;
    if (r.fiscal_year, r.fiscal_period) is distinct from (want.fiscal_year, want.fiscal_period) then
      raise exception '% — got % %', want.why, r.fiscal_year, r.fiscal_period;
    end if;
  end loop;

  if exists (select 1 from market.security_statement
              where security_id = '00000000-0000-0000-0000-000000009202'
                and (fiscal_year is not null or derived_at is null)) then
    raise exception 'a security not asked about was labelled or re-queued';
  end if;

  -- A NEW LABEL RE-QUEUES THE ROW, and an unchanged one does not.
  if (select count(*) from market.security_statement
       where security_id = '00000000-0000-0000-0000-000000009201' and derived_at is null) <> 7 then
    raise exception 'a changed label must re-queue its statement and an unchanged one must not: % re-queued',
      (select count(*) from market.security_statement
        where security_id = '00000000-0000-0000-0000-000000009201' and derived_at is null);
  end if;
  if (select derived_at from market.security_statement
       where security_id = '00000000-0000-0000-0000-000000009201'
         and period_ending = date '2023-12-20') is null then
    raise exception 'a statement whose label did not change was re-queued';
  end if;

  if market.label_fiscal_periods(array['00000000-0000-0000-0000-000000009201'::uuid]) <> 0 then
    raise exception 'a second label_fiscal_periods call rewrote rows whose label had not changed';
  end if;
end $$;

-- A TRANSITION PERIOD IS NOT A STATEMENT LABEL.
do $$
begin
  begin
    update market.security_statement set fiscal_period = 'T'
     where security_id = '00000000-0000-0000-0000-000000009201' and period_ending = date '2023-12-20';
    raise exception 'security_statement accepted fiscal_period T';
  exception when check_violation then null;
  end;
end $$;

select market.derive_security_metrics(null);

do $$
declare r record; n integer;
begin
  select fiscal_year, fiscal_period into r from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009201' and metric_code = 'revenue'
     and period_type = 'quarter' and as_of = date '2024-09-30';
  if (r.fiscal_year, r.fiscal_period) is distinct from (2024::smallint, 'Q4') then
    raise exception 'the metric did not take its statement''s label: % %', r.fiscal_year, r.fiscal_period;
  end if;

  select fiscal_year, fiscal_period into r from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009201' and metric_code = 'revenue'
     and period_type = 'annual' and as_of = date '2024-10-06';
  if (r.fiscal_year, r.fiscal_period) is distinct from (2024::smallint, 'FY') then
    raise exception 'the annual metric did not take FY2024: % %', r.fiscal_year, r.fiscal_period;
  end if;

  select fiscal_year, fiscal_period, value into r from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009201' and metric_code = 'free_cash_flow'
     and period_type = 'quarter' and as_of = date '2024-09-30';
  if (r.fiscal_year, r.fiscal_period, r.value) is distinct from (2024::smallint, 'Q4', 40::numeric) then
    raise exception 'derived free cash flow must carry its period''s label: % % %', r.fiscal_year, r.fiscal_period, r.value;
  end if;

  select fiscal_year, fiscal_period into r from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009201' and metric_code = 'revenue'
     and period_type = 'quarter' and as_of = date '2022-06-30';
  if r.fiscal_year is not null or r.fiscal_period is not null then
    raise exception 'a retracted label stayed on the metric: % %', r.fiscal_year, r.fiscal_period;
  end if;
end $$;

-- AN UNCHANGED METRIC IS NOT REWRITTEN: re-queue a statement without changing it.
update market.security_statement set derived_at = null
 where security_id = '00000000-0000-0000-0000-000000009201' and statement = 'income'
   and period_ending = date '2024-09-30' and period_type = 'quarter';

do $$
declare n integer;
begin
  n := market.derive_security_metrics(null);
  if n <> 0 then
    raise exception 'derive_security_metrics rewrote % unchanged metric row(s)', n;
  end if;
end $$;

-- THE FISCAL Q4 AND THE TTM. Q1-Q3 and the year are labelled; the year less its quarters is Q4,
-- and the TTM ending there carries the label of its last quarter.
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at,
   fiscal_year, fiscal_period) values
  ('00000000-0000-0000-0000-000000009203', 'revenue', 'annual',  date '2024-09-30', 400, 'USD', 'yfinance', now(), 2024, 'FY'),
  ('00000000-0000-0000-0000-000000009203', 'revenue', 'quarter', date '2023-12-31', 100, 'USD', 'yfinance', now(), 2024, 'Q1'),
  ('00000000-0000-0000-0000-000000009203', 'revenue', 'quarter', date '2024-03-31', 100, 'USD', 'yfinance', now(), 2024, 'Q2'),
  ('00000000-0000-0000-0000-000000009203', 'revenue', 'quarter', date '2024-06-30', 100, 'USD', 'yfinance', now(), 2024, 'Q3');

select market.derive_ttm('00000000-0000-0000-0000-000000009203'::uuid);

do $$
declare r record;
begin
  select fiscal_year, fiscal_period, value into r from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009203' and metric_code = 'revenue'
     and period_type = 'quarter' and source_code = 'derived-q4';
  if (r.fiscal_year, r.fiscal_period, r.value) is distinct from (2024::smallint, 'Q4', 100::numeric) then
    raise exception 'the derived fourth quarter must be FY2024 Q4: % % %', r.fiscal_year, r.fiscal_period, r.value;
  end if;

  select fiscal_year, fiscal_period, value into r from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009203' and metric_code = 'revenue'
     and period_type = 'ttm' and as_of = date '2024-09-30';
  if (r.fiscal_year, r.fiscal_period, r.value) is distinct from (2024::smallint, 'Q4', 400::numeric) then
    raise exception 'the TTM must carry its last quarter''s label: % % %', r.fiscal_year, r.fiscal_period, r.value;
  end if;
end $$;

\echo ok a statement takes its own fiscal period, and its metrics, fourth quarter and TTM carry it

rollback;
