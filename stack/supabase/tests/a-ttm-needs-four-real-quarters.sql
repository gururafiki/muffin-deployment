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
