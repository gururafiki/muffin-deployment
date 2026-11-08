-- A 52/53-WEEK QUARTER TAKES ITS LABEL FROM A MONTH-END DATE. Migration 20261108230000.
--
-- Yahoo dates a quarter by its month end; a 52/53-week filer's SEC quarter ends on a weekend, up to
-- 25 days away (Costco's Q2 FY2025: 2025-02-16 against Yahoo's 2025-02-28). Each rule gets a row
-- where the wrong rule answers differently:
--   (a) a 52/53-week quarter 12 days off is labelled;
--   (b) the same company's Q1 2026, which Yahoo dates twice (19 and 11 days off): the nearer only;
--   (c) a 52/53-week ANNUAL row 15 days off stays unlabelled (quarters only);
--   (d) an ordinary calendar's quarter 15 days off stays unlabelled (52/53-week only);
--   (e) two rows of one source within 10 days of one period both keep their label, as before.

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
  ('00000000-0000-0000-0000-000000009301', 'T93 A Warehouse Club', 'equity', 'ZF'),
  ('00000000-0000-0000-0000-000000009302', 'T93 Calendar Quarters', 'equity', 'ZF')
on conflict (security_id) do nothing;

insert into market.fiscal_calendar
  (security_id, regime, source_code, year_end_month, year_end_day, is_52_53_week, week_end_isodow,
   first_year_end, last_year_end, change_kind) values
  ('00000000-0000-0000-0000-000000009301', 1, 'sec-submissions', 8, null, true, 7,
   date '2020-08-30', null, 'initial'),
  ('00000000-0000-0000-0000-000000009302', 1, 'sec-submissions', 12, 31, false, null,
   date '2020-12-31', null, 'initial');

insert into market.fiscal_period
  (security_id, regime, fiscal_year, fiscal_period, period_start, period_end, is_canonical,
   is_observed, source_code) values
  ('00000000-0000-0000-0000-000000009301', 1, 2025, 'Q2', date '2024-11-25', date '2025-02-16', true, true, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009301', 1, 2025, 'FY', date '2024-09-02', date '2025-08-31', true, true, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009301', 1, 2026, 'Q1', date '2025-09-01', date '2026-04-19', true, true, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009301', 1, 2026, 'Q3', date '2026-04-20', date '2026-07-12', true, true, 'sec-submissions'),
  ('00000000-0000-0000-0000-000000009302', 1, 2025, 'Q1', date '2025-01-01', date '2025-03-31', true, true, 'sec-submissions');

insert into market.security_statement
  (security_id, statement, period_ending, period_type, currency, data, source_code, as_of,
   derived_at, fiscal_year, fiscal_period) values
  -- (a) 12 days after a 52/53-week Q2
  ('00000000-0000-0000-0000-000000009301', 'income', date '2025-02-28', 'quarter', 'USD', '{"total_revenue": 1}'::jsonb, 'yfinance', now(), now(), null, null),
  -- (b) one quarter dated twice by one source: 19 days before, and 11 days after
  ('00000000-0000-0000-0000-000000009301', 'income', date '2026-03-31', 'quarter', 'USD', '{"total_revenue": 2}'::jsonb, 'yfinance', now(), now(), null, null),
  ('00000000-0000-0000-0000-000000009301', 'income', date '2026-04-30', 'quarter', 'USD', '{"total_revenue": 3}'::jsonb, 'yfinance', now(), now(), null, null),
  -- (c) an annual row 15 days after the 52/53-week year end
  ('00000000-0000-0000-0000-000000009301', 'income', date '2025-09-15', 'annual',  'USD', '{"total_revenue": 4}'::jsonb, 'yfinance', now(), now(), null, null),
  -- (e) two rows of one source, 3 and 6 days from Q3: both within 10, both keep the label
  ('00000000-0000-0000-0000-000000009301', 'income', date '2026-07-09', 'quarter', 'USD', '{"total_revenue": 5}'::jsonb, 'yfinance', now(), now(), null, null),
  ('00000000-0000-0000-0000-000000009301', 'income', date '2026-07-18', 'quarter', 'USD', '{"total_revenue": 6}'::jsonb, 'yfinance', now(), now(), null, null),
  -- (d) an ordinary calendar's quarter, 15 days off
  ('00000000-0000-0000-0000-000000009302', 'income', date '2025-04-15', 'quarter', 'USD', '{"total_revenue": 7}'::jsonb, 'yfinance', now(), now(), null, null);

select market.label_fiscal_periods(array['00000000-0000-0000-0000-000000009301'::uuid,
                                         '00000000-0000-0000-0000-000000009302'::uuid]);

do $$
declare
  club constant uuid := '00000000-0000-0000-0000-000000009301';
  plain constant uuid := '00000000-0000-0000-0000-000000009302';
  lbl text;
  n int;
begin
  select fiscal_year || fiscal_period into lbl from market.security_statement
   where security_id = club and period_ending = '2025-02-28';
  if lbl is distinct from '2025Q2' then
    raise exception '(a) a 52/53-week quarter 12 days off must take its label; got %', lbl;
  end if;

  select fiscal_year || fiscal_period into lbl from market.security_statement
   where security_id = club and period_ending = '2026-04-30';
  if lbl is distinct from '2026Q1' then
    raise exception '(b) the nearer of two dates for one quarter must take the label; got %', lbl;
  end if;
  select fiscal_year || fiscal_period into lbl from market.security_statement
   where security_id = club and period_ending = '2026-03-31';
  if lbl is not null then
    raise exception '(b) the farther of two dates for one quarter must stay unlabelled; got %', lbl;
  end if;

  select fiscal_year || fiscal_period into lbl from market.security_statement
   where security_id = club and period_ending = '2025-09-15';
  if lbl is not null then
    raise exception '(c) an annual row 15 days off must stay unlabelled (the wider window is for quarters); got %', lbl;
  end if;

  select fiscal_year || fiscal_period into lbl from market.security_statement
   where security_id = plain and period_ending = '2025-04-15';
  if lbl is not null then
    raise exception '(d) an ordinary calendar''s quarter 15 days off must stay unlabelled; got %', lbl;
  end if;

  select count(*) into n from market.security_statement
   where security_id = club and period_ending in ('2026-07-09', '2026-07-18')
     and fiscal_year = 2026 and fiscal_period = 'Q3';
  if n <> 2 then
    raise exception '(e) two rows within 10 days of one period both keep the label, as before; got %', n;
  end if;

  raise notice 'ok  a 52/53-week quarter takes the label of a month-end date within 25 days; the nearer of two dates wins';
end $$;

rollback;
