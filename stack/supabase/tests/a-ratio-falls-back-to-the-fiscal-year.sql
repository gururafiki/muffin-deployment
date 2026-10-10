-- A RATIO USES THE TTM WHERE THERE IS ONE AND THE FISCAL YEAR WHERE THERE IS NOT, NEVER BOTH, AND
-- SAYS WHICH. A HALF-YEAR BALANCE SHEET COUNTS AS A BALANCE SHEET.
--
-- WHY THIS IS A TEST. Decided 2026-10-10: semi-annual reporters have no TTM (Yahoo gives them no
-- interim flows), and a company whose fourth quarter cannot be derived loses its TTM. Each rule here
-- fails as a believable number:
--   * mixing the TTM and the year in one series lets the view's max() take the bigger, so a P/E
--     quietly reads off the wrong earnings;
--   * a net margin over a year's net income and a trailing revenue divides two different periods;
--   * without halves, P/B vanishes for every semi-annual reporter the company lane re-files.
-- Bars are older than the daily arm's 400 days, so these rows come from the WEEKLY arm, each date
-- alone in its week.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-xbrl','SEC XBRL',275) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZY','Yearland','ZY',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000021001', 'T210 Annual Only',   'equity', 'ZY', 'USD'),
  ('00000000-0000-0000-0000-000000021002', 'T210 Both',          'equity', 'ZY', 'USD'),
  ('00000000-0000-0000-0000-000000021003', 'T210 Halves',        'equity', 'ZY', 'USD'),
  ('00000000-0000-0000-0000-000000021004', 'T210 Mixed Margins', 'equity', 'ZY', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T210A', '00000000-0000-0000-0000-000000021001', 'sec-xbrl'),
  ('ticker', 'T210B', '00000000-0000-0000-0000-000000021002', 'sec-xbrl'),
  ('ticker', 'T210C', '00000000-0000-0000-0000-000000021003', 'sec-xbrl'),
  ('ticker', 'T210D', '00000000-0000-0000-0000-000000021004', 'sec-xbrl')
on conflict (kind_code, value) do nothing;

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  -- A: only a fiscal year of EPS.
  ('00000000-0000-0000-0000-000000021001','eps_diluted','annual',date '2024-12-31', 4,'USD','sec-xbrl'),
  -- B: a TTM AND a NEWER fiscal year. Dated so the two rules disagree on the bar: in one series the
  --    year's span starts after the TTM's and would take the bar (P/E 5); kept out, the TTM's span
  --    still covers it (P/E 20). With the year OLDER than the TTM both rules answer 20.
  ('00000000-0000-0000-0000-000000021002','eps_diluted','ttm',   date '2024-12-01', 2,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000021002','eps_diluted','annual',date '2025-01-01', 8,'USD','sec-xbrl'),
  -- C: the balance sheet at a half-year date only.
  ('00000000-0000-0000-0000-000000021003','total_equity',  'half',date '2025-01-01', 500,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000021003','shares_diluted','half',date '2025-01-01', 100,'USD','sec-xbrl'),
  -- D: a trailing revenue and only a fiscal year of net income.
  ('00000000-0000-0000-0000-000000021004','revenue',   'ttm',   date '2025-01-01', 1000,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000021004','net_income','annual',date '2024-12-31',  100,'USD','sec-xbrl')
on conflict do nothing;

insert into market.price_bar (security_id, trade_date, close, source_code) values
  ('00000000-0000-0000-0000-000000021001', date '2025-03-01', 40, 'yfinance'),
  ('00000000-0000-0000-0000-000000021002', date '2025-03-01', 40, 'yfinance'),
  ('00000000-0000-0000-0000-000000021003', date '2025-03-01', 40, 'yfinance'),
  ('00000000-0000-0000-0000-000000021004', date '2025-03-01', 40, 'yfinance')
on conflict (security_id, trade_date) do nothing;

refresh materialized view market.symbol_security;

do $$
declare v numeric; b text;
begin
  -- 1. NO TTM: THE FISCAL YEAR, SAID. 40 / 4 = 10.
  select pe_ratio, eps_basis into v, b from market.security_ratio_series
   where symbol = 'T210A' and date = date '2025-03-01';
  if v is distinct from 10 or b is distinct from 'annual' then
    raise exception 'a security with only a fiscal year of EPS has P/E % on basis % — expected 10 on ''annual''',
      coalesce(v::text, '<null>'), coalesce(b, '<null>');
  end if;

  -- 2. A TTM, AND THE YEAR NEVER JOINS IT. 40 / 2 = 20; with both in one series the newer year takes
  --    the bar and gives 40 / 8 = 5.
  select pe_ratio, eps_basis into v, b from market.security_ratio_series
   where symbol = 'T210B' and date = date '2025-03-01';
  if v is distinct from 20 or b is distinct from 'ttm' then
    raise exception 'a security with a TTM has P/E % on basis % — expected 20 on ''ttm''; 5 means the fiscal year entered the TTM series',
      coalesce(v::text, '<null>'), coalesce(b, '<null>');
  end if;

  -- 3. A HALF-YEAR BALANCE SHEET IS A BALANCE SHEET: 40 / (500 / 100) = 8.
  select pb_ratio into v from market.security_ratio_series
   where symbol = 'T210C' and date = date '2025-03-01';
  if v is distinct from 8 then
    raise exception 'P/B from a half-year balance sheet is %, expected 8', coalesce(v::text, '<null>');
  end if;

  -- 4. A MARGIN NEEDS BOTH SIDES ON ONE BASIS.
  select net_margin_pct into v from market.security_ratio_series
   where symbol = 'T210D' and date = date '2025-03-01';
  if v is not null then
    raise exception 'a net margin of % divides a fiscal year''s net income by a trailing revenue', v;
  end if;

  raise notice '  ok  a ratio falls back to the fiscal year, says so, never mixes the two, and reads halves';
end $$;

rollback;

\echo 'ok: a ratio falls back to the fiscal year and says so'
