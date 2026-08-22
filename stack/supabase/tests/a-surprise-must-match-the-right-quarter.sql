-- BEATING AN ESTIMATE FOR THE WRONG QUARTER IS NOT A SURPRISE.
--
-- Two things decide whether this view says anything true, and both are easy to get wrong in a way
-- that produces a plausible number:
--
--   * THE PERIOD MATCH. `earnings_calendar.period_ending` is a MONTH ('2026-06') and the metric's
--     `as_of` is a DATE. A 52/53-week fiscal calendar ends a quarter on the nearest Saturday —
--     AAPL's Q2 is 2026-03-28, not the 31st — and can land either side of a month boundary. String
--     equality would silently drop every such filer, which is most of US retail and tech.
--   * THE SIGN. A company expected to LOSE 0.10 that loses only 0.05 has BEATEN the estimate.
--     Dividing by the raw consensus rather than its magnitude reports that as -50%.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('nasdaq','Nasdaq',60), ('sec-xbrl','SEC XBRL company facts',275)
  on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Surpriseland','ZW',false)
  on conflict (iso2) do nothing;
insert into market.metric (code, name, category, unit) values ('eps_diluted','Diluted EPS','income_statement','ratio')
  on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000012001','T120 Fiscal','equity','ZW'),
  ('00000000-0000-0000-0000-000000012002','T120 Lossmaker','equity','ZW'),
  ('00000000-0000-0000-0000-000000012003','T120 Future','equity','ZW')
on conflict (security_id) do nothing;

insert into market.earnings_calendar
  (symbol, report_date, security_id, period_ending, eps_consensus, source_code) values
  -- Reported, and the quarter ends on the 28th — a 52/53-week calendar, three days before the
  -- month end named in `period_ending`.
  ('T120A', current_date - 10, '00000000-0000-0000-0000-000000012001', '2026-06', 2.00, 'nasdaq'),
  -- Reported, and both figures are NEGATIVE: expected -0.10, actual -0.05, which is a BEAT.
  ('T120B', current_date - 10, '00000000-0000-0000-0000-000000012002', '2026-06', -0.10, 'nasdaq'),
  -- NOT yet reported. A consensus with no actual behind it must produce nothing.
  ('T120C', current_date + 20, '00000000-0000-0000-0000-000000012003', '2026-06', 1.00, 'nasdaq')
on conflict (symbol, report_date) do nothing;

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  -- ENDS IN JULY while the period is named '2026-06'. A 52/53-week calendar closes on the
  -- Saturday nearest the month end, which lands in the FOLLOWING month roughly half the time — and
  -- a date inside June would be matched by exact string equality too, so the fixture would not be
  -- testing the widening at all.
  ('00000000-0000-0000-0000-000000012001','eps_diluted','quarter', date '2026-07-04',  2.50,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000012002','eps_diluted','quarter', date '2026-06-30', -0.05,'USD','sec-xbrl'),
  -- An actual for the FUTURE company IN THE MATCHING PERIOD. It must be excluded by the report
  -- date alone — if it sat in a different quarter the period match would exclude it anyway and the
  -- test would prove nothing about the report-date filter.
  ('00000000-0000-0000-0000-000000012003','eps_diluted','quarter', date '2026-06-30',  0.90,'USD','sec-xbrl')
on conflict do nothing;

do $$
declare v numeric; b boolean; n integer;
begin
  -- 1. A 52/53-WEEK QUARTER STILL MATCHES. Ending 2026-06-28 against a period named '2026-06'.
  --    String equality on the month would drop this filer entirely and report no surprise at all.
  select surprise into v from market.security_earnings_surprise where symbol = 'T120A';
  if v is distinct from 0.50 then
    raise exception 'the fiscal-calendar quarter produced a surprise of % , expected 0.50 (2.50 actual against a 2.00 estimate) — a quarter ending on the 28th did not match the month named 2026-06', coalesce(v::text,'<null>');
  end if;

  -- 2. AND ITS PERCENTAGE IS RIGHT.
  select surprise_pct into v from market.security_earnings_surprise where symbol = 'T120A';
  if v is distinct from 25.00 then
    raise exception 'the surprise percentage is % , expected 25.00', coalesce(v::text,'<null>');
  end if;

  -- 3. LOSING LESS THAN EXPECTED IS A BEAT. -0.05 against an expected -0.10 is +50%, not -50%:
  --    dividing by the raw consensus rather than its magnitude flips the sign on every
  --    loss-making company, which is a whole class of security reported backwards.
  select surprise_pct, beat into v, b from market.security_earnings_surprise where symbol = 'T120B';
  if v is distinct from 50.00 then
    raise exception 'a company expected to lose 0.10 that lost 0.05 scored % , expected +50.00 — dividing by the signed estimate reports a beat as a miss', coalesce(v::text,'<null>');
  end if;
  if b is not true then
    raise exception 'losing less than expected is not flagged as a beat';
  end if;

  -- 4. AN UNREPORTED QUARTER PRODUCES NOTHING. A consensus for a quarter that has not happened has
  --    nothing to be compared against, and pairing it with an older actual would invent a surprise.
  select count(*) into n from market.security_earnings_surprise where symbol = 'T120C';
  if n <> 0 then
    raise exception 'a quarter that has not been reported yet produced a surprise — an estimate was paired with an actual from a different period';
  end if;
end $$;

rollback;

\echo 'ok: a surprise must match the right quarter'
