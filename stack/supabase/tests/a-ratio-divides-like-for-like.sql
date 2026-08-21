-- A RATIO DIVIDES LIKE FOR LIKE, HOLDS ITS VALUE BETWEEN REPORTS, AND REFUSES A BAD DENOMINATOR.
--
-- WHY THIS IS A TEST. Every defect here yields a NUMBER in a believable range:
--
--   * dividing a USD price by a DKK EPS gives an ADR a P/E wrong by the exchange rate — the
--     Alibaba shape, and the reason the currencies must be compared rather than assumed;
--   * interpolating a metric between reports makes P/E drift on days nothing was reported,
--     which reads as market movement;
--   * a negative EPS gives a negative P/E, and charting it draws a mirror of the price.
--
-- None of them can throw, and none shows in a row count.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-xbrl','SEC XBRL',275) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.currency (code, name) values ('DKK','Krone') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Ratioland','ZW',false)
  on conflict (iso2) do nothing;

-- A: a domestic filer — reports and trades in USD.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000010501', 'T105 Domestic', 'equity', 'ZW', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T105A', '00000000-0000-0000-0000-000000010501', 'sec-xbrl')
on conflict (kind_code, value) do nothing;

-- B: an ADR — reports in DKK, trades in USD. Every price ratio must be withheld.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000010502', 'T105 ADR', 'equity', 'ZW', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T105B', '00000000-0000-0000-0000-000000010502', 'sec-xbrl')
on conflict (kind_code, value) do nothing;

-- Two reports for A, and EPS FALLS across them — 4.00 from 2025-01-01, then 2.00 from 2025-07-01.
-- The direction is load-bearing: the view aggregates with `max()`, so if a bar were allowed to
-- match BOTH spans an increasing series would still yield the newer value and the bug would be
-- invisible. Falling, the stale value wins and the test can see it.
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000010501','eps_diluted','ttm',date '2025-01-01', 4,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010501','eps_diluted','ttm',date '2025-07-01', 2,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010502','eps_diluted','ttm',date '2025-01-01', 2,'DKK','sec-xbrl')
on conflict do nothing;

-- A DISCRETE QUARTER FOR THE SAME METRIC, LARGER THAN THE TTM. A price divided by one quarter's
-- earnings is not a P/E, and if both period types reached the same span partition the `max()` in
-- the view would take this one — 9 over 4 — for a chart that gives no sign of it.
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000010501','eps_diluted','quarter',date '2025-02-01', 9,'USD','sec-xbrl')
on conflict do nothing;

-- A STOCK metric is a balance at an instant and has NO ttm — equity and net income together give
-- an ROE, so the two period types must be selected by kind rather than by one rule for both.
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000010501','net_income','ttm',    date '2025-01-01', 100,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010501','total_equity','quarter',date '2025-01-01', 500,'USD','sec-xbrl')
on conflict do nothing;

-- C: no currency on either side. A yfinance-derived metric carries none, and a security promoted
-- from the directory may have none either — two unknowns are not a match.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000010503', 'T105 Unknown Currency', 'equity', 'ZW', null)
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T105C', '00000000-0000-0000-0000-000000010503', 'sec-xbrl')
on conflict (kind_code, value) do nothing;
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000010503','eps_diluted','ttm',date '2025-01-01', 2, null,'sec-xbrl')
on conflict do nothing;
insert into market.security_price (security_id, date, close, grain) values
  ('00000000-0000-0000-0000-000000010503', date '2025-03-01', 40, 'daily')
on conflict (security_id, grain, date) do nothing;

-- Price bars either side of the second report, plus one for the ADR.
insert into market.security_price (security_id, date, close, grain) values
  ('00000000-0000-0000-0000-000000010501', date '2025-03-01', 40, 'daily'),
  ('00000000-0000-0000-0000-000000010501', date '2025-06-30', 40, 'daily'),
  ('00000000-0000-0000-0000-000000010501', date '2025-08-01', 40, 'daily'),
  ('00000000-0000-0000-0000-000000010502', date '2025-03-01', 40, 'daily')
on conflict (security_id, grain, date) do nothing;

refresh materialized view market.symbol_security;

do $$
declare v numeric; n integer; b boolean;
begin
  -- 1. THE DIVISION IS RIGHT. 40 / 2 = 20.
  select pe_ratio into v from market.security_ratio_series
   where symbol = 'T105A' and date = date '2025-03-01';
  if v is distinct from 10 then
    raise exception 'P/E is % , expected 10 (close 40 / EPS 4)', coalesce(v::text,'<null>');
  end if;

  -- 2. IT HOLDS ITS VALUE UNTIL THE NEXT REPORT. Same EPS on 2025-06-30, the day before the new
  --    one lands — a metric that drifted between reports would show market movement that is not
  --    there.
  select pe_ratio into v from market.security_ratio_series
   where symbol = 'T105A' and date = date '2025-06-30';
  if v is distinct from 10 then
    raise exception 'P/E drifted between reports: % on the day before the new EPS, expected 10', v;
  end if;

  -- 3. AND IT STEPS ON THE REPORT. Same price, new EPS: 40 / 4 = 10.
  select pe_ratio into v from market.security_ratio_series
   where symbol = 'T105A' and date = date '2025-08-01';
  if v is distinct from 20 then
    raise exception
      'P/E did not step on the new report: % , expected 20 (40 / 2). A bar matching BOTH spans takes max(4,2)=4 and answers 10 — which is the OLD value, and exactly why the span needs an upper bound', coalesce(v::text,'<null>');
  end if;

  -- 3b. TWO UNKNOWN CURRENCIES ARE NOT A MATCH. `null = null` is not true in SQL, but a comparison
  --     written as `is distinct from` makes them equal — and then a metric of unknown currency is
  --     divided into a price of unknown currency and reported as comparable.
  select currency_comparable into b from market.security_ratio_series
   where symbol = 'T105C' and date = date '2025-03-01';
  if b is not false then
    raise exception 'currency_comparable is % where NEITHER side has a currency — two unknowns are not a match', b;
  end if;

  -- 3c. A FLOW COMES FROM THE TTM, NEVER FROM A SINGLE QUARTER. Assertion 1 already pins the
  --     value; this one names the reason, because the failure is a plausible number rather than
  --     an error.
  select pe_ratio into v from market.security_ratio_series
   where symbol = 'T105A' and date = date '2025-03-01';
  if v is distinct from 10 then
    raise exception
      'P/E is % — a discrete quarter (EPS 9) is in play alongside the TTM (EPS 4); a price over one quarter of earnings is not a P/E', v;
  end if;

  -- 3d. A STOCK COMES FROM THE LATEST QUARTER, because it has no TTM to come from. ROE needs no
  --     currency agreement: 100 / 500 = 20%.
  select roe_pct into v from market.security_ratio_series
   where symbol = 'T105A' and date = date '2025-03-01';
  if v is distinct from 20 then
    raise exception
      'ROE is % , expected 20 (net income 100 / equity 500). Equity is a BALANCE and is only ever reported as an instant — looking for a ttm row finds nothing and the ratio vanishes', coalesce(v::text,'<null>');
  end if;

  -- 4. AN ADR DIVIDES NOTHING. USD price over DKK earnings is wrong by the exchange rate and looks
  --    completely ordinary — 40/2 = 20 here, a perfectly plausible P/E for a company whose real
  --    one is nothing like it.
  select pe_ratio, currency_comparable into v, b from market.security_ratio_series
   where symbol = 'T105B' and date = date '2025-03-01';
  if v is not null then
    raise exception 'the ADR got a P/E of % — a USD price over DKK earnings is wrong by the FX rate and reads as an ordinary number', v;
  end if;
  if b is not false then
    raise exception 'currency_comparable is % for a DKK filer quoted in USD', b;
  end if;

  -- 5. A NEGATIVE DENOMINATOR YIELDS NOTHING. A "P/E of -20" charts a mirror of the price.
  update market.security_metric set value = -4
   where security_id = '00000000-0000-0000-0000-000000010501' and as_of = date '2025-01-01';
  select pe_ratio into v from market.security_ratio_series
   where symbol = 'T105A' and date = date '2025-03-01';
  if v is not null then
    raise exception 'a loss-making period produced a P/E of % — that is a division, not a valuation', v;
  end if;

  -- 6. A BAR BEFORE THE FIRST REPORT HAS NO RATIO, rather than borrowing the first one backwards.
  insert into market.security_price (security_id, date, close, grain)
  values ('00000000-0000-0000-0000-000000010501', date '2024-06-01', 40, 'daily')
  on conflict (security_id, grain, date) do nothing;
  select count(*) into n from market.security_ratio_series
   where symbol = 'T105A' and date = date '2024-06-01';
  if n <> 0 then
    raise exception 'a bar predating every report produced a row — the first EPS would be projected backwards into a year it does not describe';
  end if;
end $$;

rollback;

\echo 'ok: a ratio divides like for like, steps on reports, and refuses a bad denominator'
