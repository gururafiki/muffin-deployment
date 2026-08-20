-- A PAGE THAT DOES NOT ADVANCE IS NOT A PAGE.
--
-- WHY THIS IS A TEST. Migration 90 selected `order by security_id, period_ending desc limit N` —
-- the same first N statement rows on every call. Measured in production, two identical
-- invocations returned byte-identical results:
--
--   {"resource":"security-metrics","written":7386,"remaining":104925}
--   {"resource":"security-metrics","written":7386,"remaining":104925}
--
-- It reports thousands of rows of progress and does the same work for ever. Nothing errored;
-- `pending_industry` had exactly this shape and re-fetched the same top-300 by weight on every run
-- since migration 23, never reaching row 301. The signature is a `written` that looks like
-- throughput and never moves.
--
-- The fixture uses THREE securities and a page of ONE, so a non-advancing select is arithmetically
-- unable to reach the third. With a page equal to the fixture size, every candidate rule finishes
-- in one call and they cannot be told apart.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZP','Pageland','ZP',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009201', 'T92 One',   'equity', 'ZP'),
  ('00000000-0000-0000-0000-000000009202', 'T92 Two',   'equity', 'ZP'),
  ('00000000-0000-0000-0000-000000009203', 'T92 Three', 'equity', 'ZP')
on conflict (security_id) do nothing;

insert into market.security_statement (security_id, statement, period_ending, period_type, currency, data, source_code, as_of) values
  -- EVERY `as_of` IS DISTINCT, and that is load-bearing. The function pages with
  -- `order by st.as_of limit N`; with ties the tie-break is arbitrary, so which statements a page
  -- of ONE picks varies run to run. Measured: two identical mutation runs disagreed about which
  -- guard caught which mutation. A flaky test is worse than no test.
  ('00000000-0000-0000-0000-000000009201','income',date '2025-12-31','annual',null,'{"total_revenue": 111}'::jsonb,'yfinance', now() - interval '6 hours'),
  ('00000000-0000-0000-0000-000000009202','income',date '2025-12-31','annual',null,'{"total_revenue": 222}'::jsonb,'yfinance', now() - interval '5 hours'),
  ('00000000-0000-0000-0000-000000009203','income',date '2025-12-31','annual',null,'{"total_revenue": 333}'::jsonb,'yfinance', now() - interval '4 hours')
on conflict do nothing;

-- CASH AND BALANCE ROWS TOO, so the DERIVED passes actually have something to compute. Without
-- them free cash flow and total debt produce nothing whatever their scope is, and a mutation that
-- unscopes them to a clock window passes clean — which is exactly what happened the first time
-- this file was written.
insert into market.security_statement (security_id, statement, period_ending, period_type, currency, data, source_code, as_of) values
  ('00000000-0000-0000-0000-000000009201','cash',   date '2025-12-31','annual',null,'{"operating_cash_flow": 500, "capital_expenditure": -100}'::jsonb,'yfinance', now() - interval '3 hours'),
  ('00000000-0000-0000-0000-000000009202','cash',   date '2025-12-31','annual',null,'{"operating_cash_flow": 600, "capital_expenditure": -200}'::jsonb,'yfinance', now() - interval '170 minutes'),
  ('00000000-0000-0000-0000-000000009203','cash',   date '2025-12-31','annual',null,'{"operating_cash_flow": 700, "capital_expenditure": -300}'::jsonb,'yfinance', now() - interval '160 minutes'),
  ('00000000-0000-0000-0000-000000009201','balance',date '2025-12-31','annual',null,'{"long_term_debt": 10, "current_debt_and_capital_lease_obligation": 1}'::jsonb,'yfinance', now() - interval '120 minutes'),
  ('00000000-0000-0000-0000-000000009202','balance',date '2025-12-31','annual',null,'{"long_term_debt": 20, "current_debt_and_capital_lease_obligation": 2}'::jsonb,'yfinance', now() - interval '110 minutes'),
  ('00000000-0000-0000-0000-000000009203','balance',date '2025-12-31','annual',null,'{"long_term_debt": 30, "current_debt_and_capital_lease_obligation": 3}'::jsonb,'yfinance', now() - interval '100 minutes')
on conflict do nothing;

do $$
declare n integer; seen integer;
begin
  -- Three calls with a page of ONE must cover all three securities. A select that ignores what is
  -- already derived returns the same row three times and reaches exactly one.
  perform market.derive_security_metrics(1);
  perform market.derive_security_metrics(1);
  perform market.derive_security_metrics(1);
  -- Then finish the rest; the assertion above is about the first three pages ADVANCING, the ones
  -- below about the settled state.
  perform market.derive_security_metrics(100);

  select count(distinct security_id) into seen from market.security_metric
   where security_id in ('00000000-0000-0000-0000-000000009201',
                         '00000000-0000-0000-0000-000000009202',
                         '00000000-0000-0000-0000-000000009203');
  if seen <> 3 then
    raise exception
      'three pages of one covered % of 3 securities — the page is not advancing, which reports progress and redoes the same work for ever', seen;
  end if;

  -- 2. AND THE BACKLOG AGREES. The view and the function must be the same predicate, or a count
  --    can say "done" while the function still has the row queued.
  select count(*) into n from market.pending_metrics
   where security_id in ('00000000-0000-0000-0000-000000009201',
                         '00000000-0000-0000-0000-000000009202',
                         '00000000-0000-0000-0000-000000009203');
  if n <> 0 then
    raise exception 'pending_metrics still holds % of the derived statements — the backlog and the work are different predicates and free to disagree', n;
  end if;

  -- 3. A FURTHER PAGE DOES NOTHING. The loop in the resource stops on a zero-row page, which is
  --    only safe because the page advances — with a non-advancing select this is never reached.
  select market.derive_security_metrics(10) into n;
  if n <> 0 then
    raise exception 'a page after the work is done wrote % rows — the resource stops on a zero page, so a non-zero one here means it can never stop', n;
  end if;

  -- 3a. ALL THREE STATEMENT KINDS PRODUCED METRICS. The anti-join is per (security, period,
  --     STATEMENT): asking it per (security, period) makes deriving the income statement mark the
  --     balance sheet and cash flow done for ever. Production hid that — its first drain ran
  --     against an empty table so all three kinds sat in one page — but it bites at every page
  --     boundary, and a page of ONE reproduces it immediately. Without this assertion the derived
  --     passes have nothing to compute and the scope mutations below cannot be told apart.
  select count(distinct metric_code) into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009201'
     and metric_code in ('revenue', 'operating_cash_flow', 'long_term_debt');
  if n <> 3 then
    raise exception
      'only % of the three statement kinds produced a metric — deriving one kind is marking the others done, so a company gets an income statement and no balance sheet or cash flow at all', n;
  end if;

  -- 3b. A SETTLED BACKLOG DOES NO WORK — and "no work" means no upserts, not merely no NEW rows.
  --     Migration 92 scoped the derived passes by `fetched_at > now() - 10 minutes`, so right
  --     after a drain every row was inside the window and a steady-state run re-upserted
  --     everything: measured in production, `written: 576828, pages: 21, remaining: 28`. On a
  --     10-minute cron that is ~600k upserts and the matching WAL, for ever, on one small node.
  --     A `written` that looks like a lot of work is exactly how a spinning resource stays
  --     invisible, so the assertion is on the COUNT being zero, not on the data being unchanged.
  select market.derive_security_metrics(10) into n;
  if n <> 0 then
    raise exception
      'a run against a settled backlog wrote % rows — the derived passes are scoped by something other than the page (a clock window catches every row just written), and on a 10-minute cron that repeats for ever while reporting it as throughput', n;
  end if;

  -- 4. A RE-FETCHED STATEMENT IS RE-DERIVED. `security-statements` rewrites a row with a fresh
  --    `as_of` when SEC supersedes yfinance, which is happening across the universe right now. A
  --    backlog defined as "has no metric at all" would call that done and keep the stale number.
  -- `now()` IS TRANSACTION TIME, NOT WALL CLOCK, so inside this one transaction the re-fetch and
  -- the derivation share a timestamp and `fetched_at >= as_of` holds — the row would look already
  -- derived for a reason that has nothing to do with the rule being tested. In production the two
  -- happen in different transactions and the clock really does advance; here it must be said
  -- explicitly. (`clock_timestamp()` would also work and reads as if the difference were an
  -- accident of timing rather than the point.)
  update market.security_statement
     set data = '{"total_revenue": 999}'::jsonb, as_of = now() + interval '1 second'
   where security_id = '00000000-0000-0000-0000-000000009201'
     and statement = 'income';

  select count(*) into n from market.pending_metrics
   where security_id = '00000000-0000-0000-0000-000000009201';
  if n <> 1 then
    raise exception 'a re-fetched statement is not queued for re-derivation (% rows) — the corrected filing would never reach the chart', n;
  end if;

  perform market.derive_security_metrics(10);
  select value into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009201' and metric_code = 'revenue';
  if n <> 999 then
    raise exception 'the re-derived revenue is % rather than 999 — a corrected filing must overwrite the number derived from the old one', n;
  end if;
end $$;

rollback;

\echo 'ok: a page advances, the backlog agrees with the work, and a corrected filing is re-derived'
