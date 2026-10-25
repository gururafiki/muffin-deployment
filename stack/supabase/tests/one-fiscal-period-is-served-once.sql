-- ONE FISCAL PERIOD IS SERVED ONCE, BY ITS BEST SOURCE, AND A FILING'S KIND COMES FROM ITS FORM.
--
-- Migration 20261025110000. Each rule has a fixture row the wrong rule treats differently:
--   STATEMENTS (security_statement_current)
--   - one fiscal quarter, dated two days apart by SEC and Yahoo, is ONE row, and it is SEC's (the
--     higher priority) — keyed on the end date alone it would be two;
--   - two unlabelled rows a day apart stay two rows: without a label nothing says they are one;
--   - two sources of EQUAL priority for one labelled quarter: the newer `as_of` is served;
--   METRICS (security_metric_series)
--   - two rows sixteen days apart carrying the same fiscal label are one period, served from SEC;
--     two unlabelled rows fifteen days apart are two (the 7-day rule is unchanged);
--   FILINGS (security_recent_filings)
--   - 40-F and 10-KT are annual, 10-QT and 6-K interim, an 8-K and an unknown form an event.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('yfinance','yfinance',100), ('sec-xbrl','SEC XBRL company facts',275), ('sec-submissions','SEC submissions',255),
  ('fmp','FMP',90), ('finviz','finviz',90)
on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZO','Testonceland','ZO',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009401', 'T94 Served Once', 'equity', 'ZO')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T94ONCE', '00000000-0000-0000-0000-000000009401', 'sec-xbrl')
on conflict (kind_code, value) do nothing;

do $$
begin
  if (select priority from market.data_source where code = 'sec-xbrl')
     <= (select priority from market.data_source where code = 'yfinance')
     or (select priority from market.data_source where code = 'fmp')
     <> (select priority from market.data_source where code = 'finviz') then
    raise exception 'the fixture needs sec-xbrl above yfinance and fmp equal to finviz';
  end if;
end $$;

insert into market.security_statement
  (security_id, statement, period_ending, period_type, currency, data, source_code, as_of,
   fiscal_year, fiscal_period) values
  ('00000000-0000-0000-0000-000000009401', 'income', date '2024-09-30', 'quarter', 'USD', '{"total_revenue": 100}'::jsonb, 'yfinance', now() - interval '1 hour', 2024, 'Q4'),
  ('00000000-0000-0000-0000-000000009401', 'income', date '2024-09-28', 'quarter', 'USD', '{"revenue": 101}'::jsonb,       'sec-xbrl', now() - interval '3 hours', 2024, 'Q4'),
  ('00000000-0000-0000-0000-000000009401', 'income', date '2024-06-30', 'quarter', 'USD', '{"total_revenue": 90}'::jsonb,  'yfinance', now(), null, null),
  ('00000000-0000-0000-0000-000000009401', 'income', date '2024-06-29', 'quarter', 'USD', '{"revenue": 91}'::jsonb,        'sec-xbrl', now(), null, null),
  ('00000000-0000-0000-0000-000000009401', 'income', date '2023-12-31', 'quarter', 'USD', '{"revenue": 80}'::jsonb,        'fmp',      now() - interval '2 hours', 2024, 'Q1'),
  ('00000000-0000-0000-0000-000000009401', 'income', date '2023-12-30', 'quarter', 'USD', '{"revenue": 81}'::jsonb,        'finviz',   now() - interval '1 hour', 2024, 'Q1');

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at,
   fiscal_year, fiscal_period) values
  ('00000000-0000-0000-0000-000000009401', 'revenue', 'quarter', date '2024-03-31', 50, null, 'yfinance', now(), 2024, 'Q2'),
  ('00000000-0000-0000-0000-000000009401', 'revenue', 'quarter', date '2024-03-15', 51, null, 'sec-xbrl', now(), 2024, 'Q2'),
  ('00000000-0000-0000-0000-000000009401', 'revenue', 'quarter', date '2023-09-30', 40, null, 'yfinance', now(), null, null),
  ('00000000-0000-0000-0000-000000009401', 'revenue', 'quarter', date '2023-09-15', 41, null, 'sec-xbrl', now(), null, null);

insert into market.security_filing
  (accession_number, security_id, filing_date, report_type, source_code, is_xbrl) values
  ('9400001-0001', '00000000-0000-0000-0000-000000009401', date '2026-01-01', '40-F',      'sec-submissions', true),
  ('9400001-0002', '00000000-0000-0000-0000-000000009401', date '2026-01-02', '10-KT',     'sec-submissions', true),
  ('9400001-0003', '00000000-0000-0000-0000-000000009401', date '2026-01-03', '10-QT',     'sec-submissions', true),
  ('9400001-0004', '00000000-0000-0000-0000-000000009401', date '2026-01-04', '6-K',       'sec-submissions', false),
  ('9400001-0005', '00000000-0000-0000-0000-000000009401', date '2026-01-05', '8-K',       'sec-submissions', false),
  ('9400001-0006', '00000000-0000-0000-0000-000000009401', date '2026-01-06', '10-K/A',    'sec-submissions', true),
  ('9400001-0007', '00000000-0000-0000-0000-000000009401', date '2026-01-07', 'SC 13G',    'sec-submissions', false);

refresh materialized view market.symbol_security;

do $$
declare n integer; r record; want record;
begin
  select count(*) into n from market.security_statement_current
   where symbol = 'T94ONCE' and statement = 'income';
  if n <> 4 then
    raise exception 'statements: expected 4 rows (Q4 once, two unlabelled, Q1 once), got %', n;
  end if;

  select * into r from market.security_statement_current
   where symbol = 'T94ONCE' and statement = 'income' and fiscal_period = 'Q4';
  if r.source_code is distinct from 'sec-xbrl' or r.period_ending is distinct from date '2024-09-28' then
    raise exception 'a fiscal quarter two sources report must be served once, from the higher priority: got % %',
      r.source_code, r.period_ending;
  end if;

  select * into r from market.security_statement_current
   where symbol = 'T94ONCE' and statement = 'income' and fiscal_period = 'Q1';
  if r.source_code is distinct from 'finviz' then
    raise exception 'between equal priorities the newer as_of must be served, got %', r.source_code;
  end if;

  select count(*) into n from market.security_statement_current
   where symbol = 'T94ONCE' and statement = 'income' and fiscal_period is null;
  if n <> 2 then
    raise exception 'two unlabelled rows a day apart must stay two rows, got %', n;
  end if;

  select count(*) into n from market.security_metric_series
   where symbol = 'T94ONCE' and metric_code = 'revenue' and period_type = 'quarter';
  if n <> 3 then
    raise exception 'metric series: expected 3 periods (one labelled Q2, two unlabelled), got %', n;
  end if;

  select * into r from market.security_metric_series
   where symbol = 'T94ONCE' and metric_code = 'revenue' and period_type = 'quarter'
     and fiscal_period = 'Q2';
  if (r.value, r.source_code, r.fiscal_year) is distinct from (51::numeric, 'sec-xbrl', 2024::smallint) then
    raise exception 'one labelled period sixteen days apart must be one point, served from SEC: got % % %',
      r.value, r.source_code, r.fiscal_year;
  end if;

  for want in
    select * from (values
      ('9400001-0001', 'annual'), ('9400001-0002', 'annual'), ('9400001-0003', 'interim'),
      ('9400001-0004', 'interim'), ('9400001-0005', 'event'), ('9400001-0006', 'annual'),
      ('9400001-0007', 'event')) as t(accession_number, kind)
  loop
    select f.report_type, f.kind into r from market.security_recent_filings f
     where f.accession_number = want.accession_number;
    if r.kind is distinct from want.kind then
      raise exception 'a % filing must read as %, got %', r.report_type, want.kind, r.kind;
    end if;
  end loop;
end $$;

\echo ok one fiscal period is served once, by its best source, and a filing's kind comes from its form

rollback;
