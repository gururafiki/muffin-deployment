-- `security_earnings_history` serves each company from ONE source, the one holding the most quarters
-- for it, and computes the surprise from the figures it serves (migration 20261122100000).
--
-- The fixture makes the candidate rules disagree:
--   e6b1  nasdaq 6 quarters, yfinance 4 overlapping ones with values 10x off (an ADR ratio):
--         per-company choice serves the 6 nasdaq rows only; a per-row choice would serve both
--         sources and a mixed series; choosing by priority would serve yfinance (100 > 60);
--   e6b2  yfinance only (a non-US company): its 4 quarters;
--   e6b3  a tie, 2 and 2, both current: priority decides (yfinance), so the tie-break is
--         load-bearing;
--   e6b5  alpha-vantage 8 quarters ending 2015 against nasdaq's 3 current ones: nasdaq, so a deep
--         but stale source cannot win on count (AAPL's case on production);
--   e6b4  a loss smaller than expected (actual -0.05, estimate -0.10): a +50% beat, so the surprise
--         divides by the estimate's magnitude; plus an estimate of 0: no percent.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('nasdaq','Nasdaq',60) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('alpha-vantage','Alpha Vantage',90) on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-00000000e6b1', 'E6B1 US', 'equity'),
  ('00000000-0000-0000-0000-00000000e6b2', 'E6B2 Abroad', 'equity'),
  ('00000000-0000-0000-0000-00000000e6b3', 'E6B3 Tie', 'equity'),
  ('00000000-0000-0000-0000-00000000e6b4', 'E6B4 Loss', 'equity'),
  ('00000000-0000-0000-0000-00000000e6b5', 'E6B5 Stale deep', 'equity')
on conflict (security_id) do nothing;

insert into market.security_eps_history
  (security_id, period_ending, eps_actual, eps_estimated, source_code, as_of)
select s::uuid, p::date, a, e, src, now()
  from (values
    ('00000000-0000-0000-0000-00000000e6b1', '2025-03-31', 1.00, 0.90, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b1', '2025-06-30', 1.10, 1.00, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b1', '2025-09-30', 1.20, 1.10, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b1', '2025-12-31', 1.30, 1.20, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b1', '2026-03-31', 1.40, 1.30, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b1', '2026-06-30', 1.50, 1.40, 'nasdaq')
  ) v(s, p, a, e, src);

-- The provider key (20261122110000) lets both sources state the same quarter.
insert into market.security_eps_history
  (security_id, period_ending, eps_actual, eps_estimated, source_code, as_of)
select s::uuid, p::date, a, e, src, now()
  from (values
    ('00000000-0000-0000-0000-00000000e6b1', '2025-09-30', 12.00, 11.00, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b1', '2025-12-31', 13.00, 12.00, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b1', '2026-03-31', 14.00, 13.00, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b1', '2026-06-30', 15.00, 14.00, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b2', '2025-12-31', 96.48, 74.05, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b2', '2026-03-31', 62.70, 52.65, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b2', '2026-06-30', 120.69, 82.02, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b2', '2026-09-30', 65.28, 56.38, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b3', '2026-03-31', 1.00, 1.00, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b3', '2026-06-30', 1.00, 1.00, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b3', '2026-03-31', 2.00, 2.00, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b3', '2026-06-30', 2.00, 2.00, 'yfinance'),
    ('00000000-0000-0000-0000-00000000e6b4', '2026-06-30', -0.05, -0.10, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b4', '2026-09-30', 0.10, 0.00, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b5', '2014-03-31', 0.40, 0.38, 'alpha-vantage'),
    ('00000000-0000-0000-0000-00000000e6b5', '2014-06-30', 0.41, 0.39, 'alpha-vantage'),
    ('00000000-0000-0000-0000-00000000e6b5', '2014-09-30', 0.42, 0.40, 'alpha-vantage'),
    ('00000000-0000-0000-0000-00000000e6b5', '2014-12-31', 0.43, 0.41, 'alpha-vantage'),
    ('00000000-0000-0000-0000-00000000e6b5', '2015-03-31', 0.44, 0.42, 'alpha-vantage'),
    ('00000000-0000-0000-0000-00000000e6b5', '2015-06-30', 0.45, 0.43, 'alpha-vantage'),
    ('00000000-0000-0000-0000-00000000e6b5', '2015-09-30', 0.46, 0.44, 'alpha-vantage'),
    ('00000000-0000-0000-0000-00000000e6b5', '2015-12-31', 0.47, 0.45, 'alpha-vantage'),
    ('00000000-0000-0000-0000-00000000e6b5', '2026-01-31', 1.60, 1.50, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b5', '2026-04-30', 1.70, 1.60, 'nasdaq'),
    ('00000000-0000-0000-0000-00000000e6b5', '2026-07-31', 1.80, 1.70, 'nasdaq')
  ) v(s, p, a, e, src);

do $$
declare got text;
begin
  select string_agg(concat(right(security_id::text, 4), ' ', source_code, ' ', count), ' | ' order by security_id)
    into got
    from (select security_id, source_code, count(*) from market.security_earnings_history
           where security_id::text like '00000000-0000-0000-0000-00000000e6b_'
           group by 1, 2) x;
  if got is distinct from 'e6b1 nasdaq 6 | e6b2 yfinance 4 | e6b3 yfinance 2 | e6b4 nasdaq 2 | e6b5 nasdaq 3' then
    raise exception 'each company must be served from ONE source, the one with the most quarters; got: %', got;
  end if;
  raise notice 'ok  one source per company: the most current quarters, a tie by priority';
end $$;

do $$
declare b numeric; z numeric; beat boolean;
begin
  select surprise_pct, h.beat into b, beat from market.security_earnings_history h
   where security_id = '00000000-0000-0000-0000-00000000e6b4' and period_ending = '2026-06-30';
  select surprise_pct into z from market.security_earnings_history
   where security_id = '00000000-0000-0000-0000-00000000e6b4' and period_ending = '2026-09-30';
  if b is distinct from 50.00 or beat is not true then
    raise exception 'a loss smaller than expected is a +50%% beat, got % (beat %)', b, beat;
  end if;
  if z is not null then
    raise exception 'an estimate of 0 has no surprise percent, got %', z;
  end if;
  if (select surprise_pct from market.security_earnings_history
       where security_id = '00000000-0000-0000-0000-00000000e6b2' and period_ending = '2025-12-31') is distinct from 30.29 then
    raise exception 'the surprise is computed from the served figures (96.48 against 74.05 is 30.29%%)';
  end if;
  raise notice 'ok  the surprise is computed, divided by the estimate''s magnitude';
end $$;

rollback;
