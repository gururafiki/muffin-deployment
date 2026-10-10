-- A TTM IS FOUR CONSECUTIVE QUARTERS OF A FLOW, OR IT IS NOTHING.
--
-- WHY THIS IS A TEST. Every way of getting this wrong produces a NUMBER — never an error, and
-- always one in the right order of magnitude:
--
--   * summing a balance sheet gives four times the company;
--   * summing three quarters gives a year that is 25% short;
--   * summing four rows that span two years gives a figure that is not any year's.
--
-- And TTM is the denominator of every ratio financecharts charts, so a wrong one is wrong
-- everywhere at once rather than in one place a reader might notice.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-xbrl','SEC XBRL',275) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('derived','Computed',50) on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZV','Ttmland','ZV',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000010401', 'T104 Four Quarters', 'equity', 'ZV'),
  ('00000000-0000-0000-0000-000000010402', 'T104 Missed A Filing', 'equity', 'ZV')
on conflict (security_id) do nothing;

-- A: four clean quarters of revenue (a FLOW) and of total_assets (an INSTANT).
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000010401','revenue','quarter',date '2025-03-31', 10,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010401','revenue','quarter',date '2025-06-30', 20,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010401','revenue','quarter',date '2025-09-30', 30,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010401','revenue','quarter',date '2025-12-31', 40,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010401','total_assets','quarter',date '2025-03-31',500,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010401','total_assets','quarter',date '2025-06-30',510,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010401','total_assets','quarter',date '2025-09-30',520,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010401','total_assets','quarter',date '2025-12-31',530,'USD','sec-xbrl')
on conflict do nothing;

-- B: four quarters that SPAN TWO YEARS — a missed filing. Four rows, and their sum is not a year.
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000010402','revenue','quarter',date '2024-03-31', 10,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010402','revenue','quarter',date '2024-06-30', 20,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010402','revenue','quarter',date '2025-09-30', 30,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010402','revenue','quarter',date '2025-12-31', 40,'USD','sec-xbrl')
on conflict do nothing;

do $$
declare v numeric; n integer; c text;
begin
  perform market.derive_ttm(null, 400);

  -- 1. THE FLOW SUMS. Four quarters of 10+20+30+40 is a year of 100.
  select value into v from market.security_metric
   where security_id='00000000-0000-0000-0000-000000010401'
     and metric_code='revenue' and period_type='ttm' and as_of=date '2025-12-31';
  if v is distinct from 100 then
    raise exception 'TTM revenue is % , expected 100 (10+20+30+40)', coalesce(v::text,'<null>');
  end if;

  -- 2. AND ONLY THE FOURTH QUARTER GETS ONE. A TTM at the first quarter would be a sum of one.
  select count(*) into n from market.security_metric
   where security_id='00000000-0000-0000-0000-000000010401'
     and metric_code='revenue' and period_type='ttm';
  if n <> 1 then
    raise exception '% TTM rows for four quarters, expected 1 — a TTM before the fourth quarter is a partial year wearing a full year''s name', n;
  end if;

  -- 3. AN INSTANT IS NEVER SUMMED. Total assets over four quarters is four times the company —
  --    2,060 instead of ~530, and entirely plausible on a chart.
  select count(*) into n from market.security_metric
   where security_id='00000000-0000-0000-0000-000000010401'
     and metric_code='total_assets' and period_type='ttm';
  if n <> 0 then
    raise exception 'total_assets got a TTM — a balance sheet is an INSTANT, and summing four quarters of it reports four times the company';
  end if;

  -- 4. FOUR ROWS SPANNING TWO YEARS IS NOT A YEAR. This is the case that yields a number rather
  --    than an error: 10+20+30+40 = 100 again, for a period 21 months long.
  select count(*) into n from market.security_metric
   where security_id='00000000-0000-0000-0000-000000010402' and period_type='ttm';
  if n <> 0 then
    raise exception
      'a security whose four quarters span 21 months was given a TTM — the sum looks exactly like a good one, which is why the WINDOW has to be checked and not just the count';
  end if;

  -- 5. THE CURRENCY SURVIVES THE SUM. A TTM with no currency renders unlabelled at best and with a
  --    dollar sign at worst.
  select currency_code into c from market.security_metric
   where security_id='00000000-0000-0000-0000-000000010401'
     and metric_code='revenue' and period_type='ttm';
  if c is distinct from 'USD' then
    raise exception 'the TTM lost its currency (%)', coalesce(c,'<null>');
  end if;

  -- 6. IDEMPOTENT. The pass re-runs on every derivation; a second call must not double the sum.
  perform market.derive_ttm(null, 400);
  select value into v from market.security_metric
   where security_id='00000000-0000-0000-0000-000000010401'
     and metric_code='revenue' and period_type='ttm' and as_of=date '2025-12-31';
  if v is distinct from 100 then
    raise exception 'a second derivation changed the TTM to % — it is not idempotent', v;
  end if;

  -- 7. A NEW QUARTER MOVES THE WINDOW. TTM is trailing: adding Q1-2026 must produce a second TTM
  --    of 20+30+40+50, dropping the oldest quarter rather than accumulating.
  --    `fetched_at` IS SET EXPLICITLY AHEAD. Since migration 107 the derivation is paged over
  --    `pending_ttm`, which asks whether a quarter was fetched more recently than the TTM built
  --    from it — and `now()` is TRANSACTION time, so a row written later in the same transaction
  --    carries the SAME timestamp as the TTM derived a few statements earlier. The security would
  --    not be in the backlog and this assertion would fail for a reason unrelated to the trailing
  --    window. Production is unaffected: the fetch and the derivation are separate requests.
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  values ('00000000-0000-0000-0000-000000010401','revenue','quarter',date '2026-03-31',50,'USD','sec-xbrl',
          now() + interval '1 second');
  perform market.derive_ttm(null, 400);
  select value into v from market.security_metric
   where security_id='00000000-0000-0000-0000-000000010401'
     and metric_code='revenue' and period_type='ttm' and as_of=date '2026-03-31';
  if v is distinct from 140 then
    raise exception 'the trailing window did not move: got % , expected 140 (20+30+40+50)', coalesce(v::text,'<null>');
  end if;
end $$;

rollback;

\echo 'ok: a TTM is four consecutive quarters of a flow, or it is nothing'

-- ── AND THE PAGE MUST ADVANCE ───────────────────────────────────────────────────────────────────
--
-- Migration 107 made `derive_ttm` paged because the whole-universe form timed out at 1.39M
-- quarterly rows. A page bounded by a bare `limit` over ROWS would return the same page on every
-- call — thousands of rows of "progress" and the same work for ever, which is the defect migration
-- 92 exists to correct. Three securities and a page of ONE make a non-advancing page arithmetically
-- unable to finish.

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('derived','Derived',10) on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Pageland','ZW',false)
  on conflict (iso2) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.metric (code, name, category, unit) values ('revenue','Revenue','income_statement','currency')
  on conflict (code) do nothing;

do $$
declare i integer; sid uuid; total integer := 0; n integer; before integer;
begin
  for i in 1..3 loop
    sid := ('00000000-0000-0000-0000-00000001070' || i)::uuid;
    insert into market.security (security_id, name, security_type_code, country_iso2)
    values (sid, 'T107 ' || i, 'equity', 'ZW') on conflict do nothing;
    -- Four consecutive quarters, so each security genuinely yields a TTM.
    for n in 0..3 loop
      insert into market.security_metric
        (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
      values (sid, 'revenue', 'quarter', date '2025-03-31' + (n * interval '3 months'),
              100 + n, 'USD', 'sec-xbrl', now())
      on conflict do nothing;
    end loop;
  end loop;

  select count(*) into before from market.pending_ttm;
  if before < 3 then
    raise exception 'the backlog sees only % securities, expected at least 3 — it cannot be exercised', before;
  end if;

  -- A PAGE OF ONE, called three times. If the page does not advance it returns the same security
  -- every time and the backlog never empties.
  for i in 1..3 loop
    total := total + market.derive_ttm(null, 1);
  end loop;

  select count(*) into n from market.security_metric
   where security_id in ('00000000-0000-0000-0000-000000010701','00000000-0000-0000-0000-000000010702',
                         '00000000-0000-0000-0000-000000010703')
     and period_type = 'ttm';
  if n < 3 then
    raise exception 'three calls with a page of ONE produced % TTM rows across 3 securities — the page is not advancing, it is re-deriving the same one', n;
  end if;
end $$;

rollback;

\echo 'ok: a ttm needs four real quarters, and the page advances'

-- ── AND A SECURITY THAT CANNOT FORM A TTM LEAVES THE BACKLOG AFTER ONE LOOK ─────────────────────
--
-- `pending_ttm` used to ask "is the newest TTM older than the newest quarter". A security whose four
-- quarters span two years never gets a TTM, so it stayed pending for ever: 656 of 4,094 on
-- 2026-10-10, a floor the backlog could never drain below. `derive_ttm` now records that it looked
-- (`market.ttm_derivation`), and the backlog asks whether a quarter arrived after that. Removing
-- the marker's insert, or restoring the old view, fails the first assertion; the second is what
-- keeps the marker from becoming a permanent exclusion.

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-xbrl','SEC XBRL',275) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('derived','Computed',50) on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZV','Ttmland','ZV',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000010403', 'T104 Never A Year', 'equity', 'ZV')
on conflict (security_id) do nothing;
insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000010403','revenue','quarter',date '2024-03-31', 10,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010403','revenue','quarter',date '2024-06-30', 20,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010403','revenue','quarter',date '2025-09-30', 30,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010403','revenue','quarter',date '2025-12-31', 40,'USD','sec-xbrl')
on conflict do nothing;

do $$
declare n integer;
begin
  select count(*) into n from market.pending_ttm
   where security_id = '00000000-0000-0000-0000-000000010403';
  if n <> 1 then
    raise exception 'a security with quarters and no evaluation is not in pending_ttm (% rows) — the fixture cannot exercise the rule', n;
  end if;

  perform market.derive_ttm(null, 400);

  select count(*) into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000010403' and period_type = 'ttm';
  if n <> 0 then
    raise exception 'the fixture formed a TTM (% rows) — it must be a security that cannot', n;
  end if;
  select count(*) into n from market.pending_ttm
   where security_id = '00000000-0000-0000-0000-000000010403';
  if n <> 0 then
    raise exception
      'a security whose quarters cannot form a TTM is still pending after it was evaluated — a '
      'backlog with a floor that never drains, the 656 of 2026-10-10';
  end if;

  -- A NEWER QUARTER BRINGS IT BACK. `fetched_at` is set ahead because `now()` is transaction time
  -- (see block 7 above).
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  values ('00000000-0000-0000-0000-000000010403','revenue','quarter',date '2026-03-31',50,'USD','sec-xbrl',
          now() + interval '1 second');
  select count(*) into n from market.pending_ttm
   where security_id = '00000000-0000-0000-0000-000000010403';
  if n <> 1 then
    raise exception 'a quarter that arrived after the evaluation did not re-queue the security — the marker has become a permanent exclusion';
  end if;
  raise notice '  ok  a security that cannot form a TTM leaves the backlog after one look, and a new quarter brings it back';
end $$;

rollback;

\echo 'ok: the TTM backlog drains past the securities that cannot form one'

-- ── AND A YEAR IS FOUR CONSECUTIVE QUARTERS, WITH SEC'S MISSING FOURTH DERIVED ──────────────────
--
-- SEC's XBRL writes Q1-Q3 and the 10-K carries the fourth, so the old 370-day rule summed
-- Q1 + Q2 + Q3 + the next Q1: 81,515 TTM rows in 3,439 securities on 2026-10-10. These are Apple's
-- real figures (bn USD). Its TTM revenue at 2025-12-27 was stored as 457.45; the true figure is
-- 435.62, with the fiscal Q4 derived as 416.16 - 124.30 - 95.36 - 94.04 = 102.46.

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-xbrl','SEC XBRL',275) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('derived','Computed',50) on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar'), ('EUR','Euro') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZV','Ttmland','ZV',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000010411', 'T104 Apple-shaped', 'equity', 'ZV'),
  ('00000000-0000-0000-0000-000000010412', 'T104 No Fourth Quarter', 'equity', 'ZV'),
  ('00000000-0000-0000-0000-000000010413', 'T104 Inconsistent Year', 'equity', 'ZV'),
  ('00000000-0000-0000-0000-000000010414', 'T104 Provider Q4 Nearby', 'equity', 'ZV'),
  ('00000000-0000-0000-0000-000000010415', 'T104 Two Currencies', 'equity', 'ZV')
on conflict (security_id) do nothing;

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  -- Apple: two fiscal years of Q1-Q3 plus their annuals, and the next Q1.
  ('00000000-0000-0000-0000-000000010411','revenue','quarter',date '2023-12-30',119.58,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010411','revenue','quarter',date '2024-03-30', 90.75,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010411','revenue','quarter',date '2024-06-29', 85.78,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010411','revenue','annual', date '2024-09-28',391.04,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010411','revenue','quarter',date '2024-12-28',124.30,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010411','revenue','quarter',date '2025-03-29', 95.36,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010411','revenue','quarter',date '2025-06-28', 94.04,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010411','revenue','annual', date '2025-09-27',416.16,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010411','revenue','quarter',date '2025-12-27',143.76,'USD','sec-xbrl'),
  -- ...and the row the old rule wrote, which the new one must replace.
  ('00000000-0000-0000-0000-000000010411','revenue','ttm',    date '2025-12-27',457.45,'USD','derived'),
  -- No annual, so no fourth quarter: Q1, Q2, Q3 and the next Q1 span 364 days.
  ('00000000-0000-0000-0000-000000010412','revenue','quarter',date '2024-12-28',124.30,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010412','revenue','quarter',date '2025-03-29', 95.36,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010412','revenue','quarter',date '2025-06-28', 94.04,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010412','revenue','quarter',date '2025-12-27',143.76,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010412','revenue','ttm',    date '2025-12-27',457.45,'USD','derived'),
  -- Three non-negative quarters that exceed their year: the inputs disagree.
  ('00000000-0000-0000-0000-000000010413','revenue','quarter',date '2024-12-28', 50,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010413','revenue','quarter',date '2025-03-29', 40,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010413','revenue','quarter',date '2025-06-28', 30,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010413','revenue','annual', date '2025-09-27',100,'USD','sec-xbrl'),
  -- A provider's own Q4 three days from the year end, dated by month end as Yahoo dates it.
  ('00000000-0000-0000-0000-000000010414','revenue','quarter',date '2024-12-28',124.30,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010414','revenue','quarter',date '2025-03-29', 95.36,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010414','revenue','quarter',date '2025-06-28', 94.04,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010414','revenue','annual', date '2025-09-27',416.16,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010414','revenue','quarter',date '2025-09-30',102.47,'USD','yfinance'),
  -- The year in USD, its quarters in EUR.
  ('00000000-0000-0000-0000-000000010415','revenue','quarter',date '2024-12-28',124.30,'EUR','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010415','revenue','quarter',date '2025-03-29', 95.36,'EUR','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010415','revenue','quarter',date '2025-06-28', 94.04,'EUR','sec-xbrl'),
  ('00000000-0000-0000-0000-000000010415','revenue','annual', date '2025-09-27',416.16,'USD','sec-xbrl')
on conflict do nothing;

do $$
declare v numeric; n integer; s text;
begin
  perform market.derive_ttm(null, 400);

  -- 1. THE FISCAL Q4 IS THE YEAR LESS ITS THREE QUARTERS, AND SAYS IT WAS COMPUTED.
  select value, source_code into v, s from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000010411' and metric_code = 'revenue'
     and period_type = 'quarter' and as_of = date '2025-09-27';
  if v is distinct from 102.46 or s is distinct from 'derived-q4' then
    raise exception 'the fiscal Q4 is % from %, expected 102.46 from derived-q4 (416.16 - 124.30 - 95.36 - 94.04)',
      coalesce(v::text, '<none>'), coalesce(s, '<none>');
  end if;

  -- 2. THE TTM IS FOUR CONSECUTIVE QUARTERS: 95.36 + 94.04 + 102.46 + 143.76, and the old row is gone.
  select value into v from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000010411' and metric_code = 'revenue'
     and period_type = 'ttm' and as_of = date '2025-12-27';
  if v is distinct from 435.62 then
    raise exception 'Apple-shaped TTM revenue at 2025-12-27 is %, expected 435.62 — 457.45 is Q1+Q2+Q3+next Q1, a year with its fourth quarter missing and its first counted twice',
      coalesce(v::text, '<none>');
  end if;
  -- ...and at the year end it is the year.
  select value into v from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000010411' and metric_code = 'revenue'
     and period_type = 'ttm' and as_of = date '2025-09-27';
  if v is distinct from 416.16 then
    raise exception 'the TTM at the fiscal year end is %, expected the year itself, 416.16', coalesce(v::text, '<none>');
  end if;

  -- 3. A YEAR WITH A QUARTER MISSING IS NO YEAR, AND THE OLD ROW IS RETRACTED.
  select count(*) into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000010412' and period_type = 'ttm';
  if n <> 0 then
    raise exception '% TTM rows for four quarters spanning 364 days — a quarter is missing, and the row the old rule wrote must not survive the rule', n;
  end if;

  -- 4. NO FOURTH QUARTER FROM INPUTS THAT DISAGREE: three non-negative quarters above their year.
  select count(*) into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000010413' and source_code = 'derived-q4';
  if n <> 0 then
    raise exception 'a negative fourth quarter was derived from a non-negative year and quarters (% rows)', n;
  end if;

  -- 5. NONE WHERE A PROVIDER ALREADY STATES IT, even three days off the year end.
  select count(*) into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000010414' and source_code = 'derived-q4';
  if n <> 0 then
    raise exception 'a fourth quarter was derived beside the provider''s own (% rows) — the same quarter twice, three days apart', n;
  end if;

  -- 6. NONE ACROSS TWO CURRENCIES.
  select count(*) into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000010415' and source_code = 'derived-q4';
  if n <> 0 then
    raise exception 'a fourth quarter was derived from a USD year and EUR quarters (% rows)', n;
  end if;

  raise notice '  ok  a TTM is four consecutive quarters, and SEC''s fourth quarter is derived only where it can be';
end $$;

rollback;

\echo 'ok: a year is four consecutive quarters, with the fourth derived where it can be'
