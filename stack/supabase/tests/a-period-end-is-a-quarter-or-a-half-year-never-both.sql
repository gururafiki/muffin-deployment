-- The half-year repair (migration 20261114180000) deletes the twin of the wrong type, re-files a
-- half-yearly company's remaining quarters as halves, and touches nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database deletes nothing, so applying the
-- migration set proves nothing about it. The fixture makes the candidate rules disagree:
--   * T9A1 is half-yearly: its quarter twins go, its older quarter becomes a half, and its annual
--     row and another source's quarter at the same period end stay;
--   * T9A2 is quarterly: its half twin goes, and a half row with no twin stays;
--   * T9A3 has no half row at all (Yahoo's half-year balance sheets filed as quarters): untouched;
--   * T9A4 is half-yearly PER STATEMENT and quarterly PER SECURITY (half-year balance sheets beside
--     quarter-end income stubs). The lane's `cadence` reads the union, so the repair must too: its
--     half twin goes and its income stubs stay quarters. A per-statement rule does the opposite.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('sec','SEC',250)
  on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000009a01', 'T9A1 Half-yearly', 'equity'),
  ('00000000-0000-0000-0000-000000009a02', 'T9A2 Quarterly', 'equity'),
  ('00000000-0000-0000-0000-000000009a03', 'T9A3 No half row', 'equity'),
  ('00000000-0000-0000-0000-000000009a04', 'T9A4 Stubs', 'equity')
on conflict (security_id) do nothing;

insert into market.security_statement
  (security_id, statement, period_ending, period_type, currency, data, source_code, derived_at)
values
  ('00000000-0000-0000-0000-000000009a01', 'balance', date '2024-12-31', 'quarter', 'CHF', '{"older": 1}', 'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a01', 'balance', date '2025-06-30', 'quarter', 'CHF', '{"edge": 1}', 'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a01', 'balance', date '2025-06-30', 'half',    'CHF', '{"lane": 1}', 'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a01', 'balance', date '2025-12-31', 'quarter', 'CHF', '{"edge": 2}', 'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a01', 'balance', date '2025-12-31', 'half',    'CHF', '{"lane": 2}', 'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a01', 'balance', date '2025-12-31', 'annual',  'CHF', '{"year": 1}', 'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a01', 'balance', date '2025-06-30', 'quarter', 'CHF', '{"sec": 1}',  'sec',      now()),
  ('00000000-0000-0000-0000-000000009a02', 'income',  date '2024-12-31', 'half',    'JPY', '{"alone": 1}','yfinance', now()),
  ('00000000-0000-0000-0000-000000009a02', 'income',  date '2025-03-31', 'quarter', 'JPY', '{"q": 1}',    'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a02', 'income',  date '2025-06-30', 'quarter', 'JPY', '{"q": 2}',    'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a02', 'income',  date '2025-06-30', 'half',    'JPY', '{"h": 2}',    'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a02', 'income',  date '2025-09-30', 'quarter', 'JPY', '{"q": 3}',    'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a03', 'balance', date '2025-06-30', 'quarter', 'EUR', '{"b": 1}',    'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a03', 'balance', date '2025-12-31', 'quarter', 'EUR', '{"b": 2}',    'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a04', 'balance', date '2025-06-30', 'quarter', 'HKD', '{"b": 1}',    'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a04', 'balance', date '2025-06-30', 'half',    'HKD', '{"b": 1}',    'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a04', 'balance', date '2025-12-31', 'half',    'HKD', '{"b": 2}',    'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a04', 'income',  date '2025-03-31', 'quarter', 'HKD', '{"eps": 1}',  'yfinance', now()),
  ('00000000-0000-0000-0000-000000009a04', 'income',  date '2025-09-30', 'quarter', 'HKD', '{"eps": 2}',  'yfinance', now());

delete from market.one_shot where key = 'yahoo-half-twins-2026-11-14';

\i stack/supabase/migrations/20261114180000_a_period_end_is_a_quarter_or_a_half_year_never_both.sql

do $$
declare
  got text;
  want text := concat_ws(' | ',
    '9a01 balance 2024-12-31 half sec=f {"older": 1} underived',
    '9a01 balance 2025-06-30 half sec=f {"lane": 1}',
    '9a01 balance 2025-06-30 quarter sec=t {"sec": 1}',
    '9a01 balance 2025-12-31 annual sec=f {"year": 1}',
    '9a01 balance 2025-12-31 half sec=f {"lane": 2}',
    '9a02 income 2024-12-31 half sec=f {"alone": 1}',
    '9a02 income 2025-03-31 quarter sec=f {"q": 1}',
    '9a02 income 2025-06-30 quarter sec=f {"q": 2}',
    '9a02 income 2025-09-30 quarter sec=f {"q": 3}',
    '9a03 balance 2025-06-30 quarter sec=f {"b": 1}',
    '9a03 balance 2025-12-31 quarter sec=f {"b": 2}',
    '9a04 balance 2025-06-30 quarter sec=f {"b": 1}',
    '9a04 balance 2025-12-31 half sec=f {"b": 2}',
    '9a04 income 2025-03-31 quarter sec=f {"eps": 1}',
    '9a04 income 2025-09-30 quarter sec=f {"eps": 2}');
begin
  select string_agg(
           concat_ws(' ', right(security_id::text, 4), statement, period_ending, period_type,
                     case when source_code = 'sec' then 'sec=t' else 'sec=f' end, data::text,
                     case when derived_at is null then 'underived' end),
           ' | ' order by security_id, statement, period_ending, period_type, source_code)
    into got
    from market.security_statement
   where security_id::text like '00000000-0000-0000-0000-000000009a0_';

  if got is distinct from want then
    raise exception E'the half-year repair left the wrong rows\n got: %\nwant: %', got, want;
  end if;
  raise notice 'ok  one type per period end, by the lane''s cadence; nothing else touched';
end $$;

-- ONE-SHOT: a second run with the key held changes nothing, even with a twin to find.
insert into market.security_statement
  (security_id, statement, period_ending, period_type, currency, data, source_code)
values
  ('00000000-0000-0000-0000-000000009a01', 'balance', date '2025-06-30', 'quarter', 'CHF', '{"again": 1}', 'yfinance');

\i stack/supabase/migrations/20261114180000_a_period_end_is_a_quarter_or_a_half_year_never_both.sql

do $$
begin
  if not exists (select 1 from market.security_statement
                  where security_id = '00000000-0000-0000-0000-000000009a01'
                    and period_ending = date '2025-06-30' and period_type = 'quarter'
                    and source_code = 'yfinance') then
    raise exception 'the half-year repair ran twice; its key in market.one_shot is what stops that';
  end if;
  raise notice 'ok  the repair is one-shot';
end $$;

rollback;
