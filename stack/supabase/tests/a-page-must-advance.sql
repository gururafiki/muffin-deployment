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
  ('00000000-0000-0000-0000-000000009201','income',date '2025-12-31','annual',null,'{"total_revenue": 111}'::jsonb,'yfinance', now() - interval '3 hours'),
  ('00000000-0000-0000-0000-000000009202','income',date '2025-12-31','annual',null,'{"total_revenue": 222}'::jsonb,'yfinance', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-000000009203','income',date '2025-12-31','annual',null,'{"total_revenue": 333}'::jsonb,'yfinance', now() - interval '1 hour')
on conflict do nothing;

do $$
declare n integer; seen integer;
begin
  -- Three calls with a page of ONE must cover all three securities. A select that ignores what is
  -- already derived returns the same row three times and reaches exactly one.
  perform market.derive_security_metrics(1);
  perform market.derive_security_metrics(1);
  perform market.derive_security_metrics(1);

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
   where security_id = '00000000-0000-0000-0000-000000009201';

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
