-- WHEN A PROVIDER ALLOWS 25 CALLS A DAY, THE BOUND IS THE FEATURE.
--
-- `equity/fundamental/historical_eps` has exactly one working provider — alpha_vantage at 25 calls
-- a DAY — because FMP's copy is 402 premium even for AAPL (measured with a live key). There is no
-- second source and no way to widen it, so `pending_eps_history` carries the tightest population
-- bound in this schema: 1% of a tracked fund. A looser threshold does not drain more slowly, it
-- exhausts the day's quota on the first cron run and fails every page-open after it.
--
-- This test pins that bound, and pins the cursor being a QUARTER rather than the usual week —
-- a new quarter arrives four times a year, and re-asking sooner spends a scarce budget on
-- securities that cannot have changed.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('alpha-vantage','Alpha Vantage',90), ('sec-nport','SEC N-PORT filing',300)
  on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Quotaland','ZW',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-0000000122ff','T122 Fund','equity','ZW'),
  ('00000000-0000-0000-0000-000000012201','T122 Large','equity','ZW'),
  ('00000000-0000-0000-0000-000000012202','T122 Middling','equity','ZW'),
  -- A LARGE holding whose only symbol carries an exchange suffix. alpha_vantage serves US
  -- listings; a foreign one hangs upstream until the timeout and costs a call from a 25-a-day
  -- budget to learn nothing. It must not be queued despite being big enough.
  ('00000000-0000-0000-0000-000000012203','T122 Foreign','equity','ZW')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','T122A','00000000-0000-0000-0000-000000012201','alpha-vantage'),
  ('ticker','T122B','00000000-0000-0000-0000-000000012202','alpha-vantage'),
  ('ticker','T122C.AS','00000000-0000-0000-0000-000000012203','alpha-vantage')
on conflict (kind_code, value) do nothing;

-- 2.5% and 0.7%. The second is a real position and would qualify for every OTHER backlog here —
-- `pending_management` takes anything at 0.5%. It must not qualify for this one.
insert into market.fund_holding (fund_id, security_id, as_of, weight, source_code) values
  ('00000000-0000-0000-0000-0000000122ff','00000000-0000-0000-0000-000000012201', current_date, 2.5, 'sec-nport'),
  ('00000000-0000-0000-0000-0000000122ff','00000000-0000-0000-0000-000000012202', current_date, 0.7, 'sec-nport'),
  ('00000000-0000-0000-0000-0000000122ff','00000000-0000-0000-0000-000000012203', current_date, 4.0, 'sec-nport')
on conflict do nothing;

do $$
declare n integer;
begin
  -- 1. THE LARGE HOLDING IS QUEUED.
  select count(*) into n from market.pending_eps_history where symbol = 'T122A';
  if n <> 1 then raise exception 'a 2.5%% holding is not queued for EPS history (% rows)', n; end if;

  -- 2. THE 0.7% ONE IS NOT — even though `pending_management` would take it at 0.5%. The bound is
  --    tighter here BECAUSE the provider allows 25 calls a day in total, and that difference is
  --    the whole point rather than an inconsistency.
  select count(*) into n from market.pending_eps_history where symbol = 'T122B';
  if n <> 0 then
    raise exception 'a 0.7%% holding is queued — this backlog shares a 25-call-a-DAY budget and cannot use the 0.5%% threshold the others do';
  end if;

  -- 3. A SUFFIXED SYMBOL IS NEVER QUEUED, however large the position. This one is 4% — bigger
  --    than the qualifying holding — so weight alone would rank it FIRST and burn the day's quota
  --    on a symbol alpha_vantage cannot serve. Measured: `ASML.AS` hangs until the timeout.
  select count(*) into n from market.pending_eps_history where symbol like 'T122C%';
  if n <> 0 then
    raise exception 'a suffixed foreign symbol is queued — alpha_vantage serves US listings and this would spend a 25-a-day call to time out';
  end if;

  -- 4. THE CURSOR IS A QUARTER, NOT A WEEK. A month later it must still be current: re-asking
  --    sooner spends a scarce budget on a security whose next quarter has not been filed.
  update market.security set eps_history_fetched_at = now() - interval '30 days'
   where security_id = '00000000-0000-0000-0000-000000012201';
  select count(*) into n from market.pending_eps_history where symbol = 'T122A';
  if n <> 0 then
    raise exception 'a security read 30 days ago is queued again — at 25 calls a day that is three months of budget spent re-reading unchanged quarters';
  end if;

  -- 5. AND IT DOES EXPIRE. A quarter later there is a new filing to collect.
  update market.security set eps_history_fetched_at = now() - interval '100 days'
   where security_id = '00000000-0000-0000-0000-000000012201';
  select count(*) into n from market.pending_eps_history where symbol = 'T122A';
  if n <> 1 then
    raise exception 'a security read 100 days ago is NOT queued — the cursor has become permanent and a new quarter would never be collected';
  end if;
end $$;

rollback;

\echo 'ok: a daily quota bounds the backlog'
