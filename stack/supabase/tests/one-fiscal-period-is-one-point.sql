-- One fiscal period must be one point, and the FILING's date must be the one shown.
--
-- WHY THIS EXISTS AS A TEST. The defect is a number that is merely present TWICE, with both copies
-- agreeing. No floor, no row count, no units check and no freshness rule can see it — only the
-- rendered chart, where AAPL's 2025 revenue appeared as two points three days apart.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. Four rules could be written here:
--
--   1. no collapse                     -> two points for 2025. The bug.
--   2. collapse, keep the LATEST date  -> keeps yfinance's rounded 09-30, drops the filing's 09-27
--   3. collapse, keep the EARLIEST     -> right here by luck, wrong whenever the filing is later
--   4. collapse, keep the HIGHEST-PRIORITY SOURCE -> what shipped
--
-- So the fixture gives the high-priority source the EARLIER date in one year and the LATER date in
-- the next. A fixture where the filing is always earlier cannot tell rule 3 from rule 4, and rule 3
-- would then survive a rewrite.
--
-- It also pins the boundary: 2023's two rows are 40 days apart and must stay SEPARATE, or the
-- collapse would start eating genuine periods.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('sec-xbrl','SEC XBRL company facts',275), ('yfinance','yfinance',100)
on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_derived, is_flow) values
  ('t126_revenue','T126 Revenue','income','currency',false,true)
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000126a01','T126 Filer','equity')
on conflict (security_id) do nothing;
insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000126a01','ticker','T126')
on conflict (kind_code, value) do nothing;

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, source_code) values
  -- 2025: the FILING is EARLIER than the provider.
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2025-09-27', 416200000000,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2025-09-30', 416200000000,'yfinance'),
  -- 2024: the FILING is LATER than the provider. This pair is what separates "keep the earliest"
  -- from "keep the filing" — with both years the same way round, either rule passes.
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2024-09-26', 391000000000,'yfinance'),
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2024-09-29', 391000000000,'sec-xbrl'),
  -- 2023: FORTY DAYS apart. Two genuine periods; the collapse must not touch them.
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2023-08-20', 300000000000,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2023-09-29', 383300000000,'sec-xbrl')
on conflict do nothing;

-- `security_metric_series` resolves the symbol through `market.symbol_security`, which is
-- MATERIALIZED — so the security inserted above is invisible to it until the map is rebuilt and
-- the inner join drops every row, failing every assertion below for a reason unrelated to its
-- subject. (Migration 174 moved that join off the `security_symbol` VIEW because filtering it by
-- symbol walked all 27,600 securities and timed out for anon.) NON-concurrently, deliberately:
-- `refresh ... concurrently` cannot run inside a transaction block, and a test that cannot roll
-- back is not a test.
refresh materialized view market.symbol_security;

do $$
declare
  n2025 integer; n2024 integer; n2023 integer;
  d2025 date;    d2024 date;
begin
  select count(*) into n2025 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2025-01-01' and '2025-12-31';
  if n2025 <> 1 then
    raise exception 'the 2025 fiscal year yields % rows, expected 1 — one fiscal year reported by '
                    'two sources is being plotted twice, with values that agree', n2025;
  end if;

  select as_of into d2025 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2025-01-01' and '2025-12-31';
  if d2025 <> date '2025-09-27' then
    raise exception '2025 survived as %, expected the filing date 2025-09-27 — the provider''s '
                    'rounded month end is being preferred over the true fiscal period end', d2025;
  end if;

  select count(*) into n2024 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2024-01-01' and '2024-12-31';
  if n2024 <> 1 then
    raise exception 'the 2024 fiscal year yields % rows, expected 1', n2024;
  end if;

  select as_of into d2024 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2024-01-01' and '2024-12-31';
  if d2024 <> date '2024-09-29' then
    raise exception '2024 survived as %, expected the filing date 2024-09-29 — the rule is keeping '
                    'the EARLIEST date rather than the highest-priority SOURCE, which is right only '
                    'when the filing happens to come first', d2024;
  end if;

  select count(*) into n2023 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2023-01-01' and '2023-12-31';
  if n2023 <> 2 then
    raise exception 'two periods 40 days apart collapsed into % row(s) — the window has grown wide '
                    'enough to eat genuine periods', n2023;
  end if;

  raise notice 'ok  one fiscal period is one point, dated by the filing, and 40 days is still two';
end $$;

rollback;

-- ── AND ONE PERIOD IS ONE DATE ACROSS ALL ITS METRICS ───────────────────────────────────────────
--
-- The block above collapses one METRIC's two rows. A period has many metrics, and the sources do
-- not state the same ones: SEC gives a 52/53-week filer's quarterly revenue and operating income,
-- Yahoo alone gives its R&D. Collapsed per metric, revenue sat on SEC's date and R&D on Yahoo's, and
-- the statement table, which pivots on the date, split every quarter into two half-empty columns
-- (Apple, 2026-10-17; migration 20261017180000).
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE, as above:
--   * per-metric dates (the old view) put R&D on 2025-12-31 and 2026-03-31;
--   * the cluster's LATEST date gives 2026-03-31 for the March quarter;
--   * the cluster's EARLIEST date gives 2025-12-31 for the December quarter, where SEC's 52/53-week
--     date falls AFTER the month end (ATROB's 2026-01-03);
--   * the highest-priority row's date, what shipped, gives 2026-01-03 and 2026-03-28.
-- A quarter only Yahoo reports keeps Yahoo's date, and asking for one metric must not move it.
--
-- AND A TIE IS BROKEN BY WHERE THE ROWS SIT, NOT BY THE LATER DATE. In December 2024 SEC states
-- three metrics at the period end and an opening balance the day after, as when a new standard
-- takes effect (SAP, Toyota and Vodafone in 2017-2019). "The later date" serves the whole quarter on
-- 2025-01-01; the rule keeps 2024-12-31, and equity's period-end 500, not the restated 480.

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('sec-xbrl','SEC XBRL company facts',275), ('yfinance','yfinance',100)
on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_derived, is_flow) values
  ('t441_revenue','T441 Revenue','income','currency',false,true),
  ('t441_opinc','T441 Operating income','income','currency',false,true),
  ('t441_rd','T441 R&D','income','currency',false,true),
  ('t441_equity','T441 Equity','balance','currency',false,false)
on conflict (code) do nothing;
insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000441a01','T441 Two Calendars','equity')
on conflict (security_id) do nothing;
insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000441a01','ticker','T441')
on conflict (kind_code, value) do nothing;

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, source_code) values
  -- September: Yahoo alone.
  ('00000000-0000-0000-0000-000000441a01','t441_revenue','quarter','2025-09-30',  90,'yfinance'),
  ('00000000-0000-0000-0000-000000441a01','t441_rd',     'quarter','2025-09-30',   9,'yfinance'),
  -- December: SEC's date falls AFTER Yahoo's month end.
  ('00000000-0000-0000-0000-000000441a01','t441_revenue','quarter','2026-01-03', 200,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000441a01','t441_opinc',  'quarter','2026-01-03',  60,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000441a01','t441_revenue','quarter','2025-12-31', 201,'yfinance'),
  ('00000000-0000-0000-0000-000000441a01','t441_rd',     'quarter','2025-12-31',  20,'yfinance'),
  -- March: SEC's date falls BEFORE it.
  ('00000000-0000-0000-0000-000000441a01','t441_revenue','quarter','2026-03-28', 100,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000441a01','t441_opinc',  'quarter','2026-03-28',  30,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000441a01','t441_revenue','quarter','2026-03-31', 101,'yfinance'),
  ('00000000-0000-0000-0000-000000441a01','t441_rd',     'quarter','2026-03-31',  10,'yfinance'),
  -- December 2024: SEC alone, three metrics at the period end and a restated opening balance.
  ('00000000-0000-0000-0000-000000441a01','t441_revenue','quarter','2024-12-31', 300,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000441a01','t441_opinc',  'quarter','2024-12-31',  90,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000441a01','t441_equity', 'quarter','2024-12-31', 500,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000441a01','t441_equity', 'quarter','2025-01-01', 480,'sec-xbrl')
on conflict do nothing;

refresh materialized view market.symbol_security;

do $$
declare dates text; v numeric; d date; n integer;
begin
  -- 1. THREE QUARTERS, THREE DATES, whatever metric holds them.
  select string_agg(distinct as_of::text, ', ' order by as_of::text) into dates
    from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000441a01' and period_type = 'quarter';
  if dates is distinct from '2024-12-31, 2025-09-30, 2026-01-03, 2026-03-28' then
    raise exception 'the quarters are served on %, expected 2024-12-31, 2025-09-30, 2026-01-03, 2026-03-28. A month-end date beside an SEC date means one quarter is split across two columns; 2025-01-01 means a tie went to the later date',
      coalesce(dates, '<none>');
  end if;

  -- 2. YAHOO'S R&D IS SERVED AT SEC'S DATE, WITH YAHOO'S VALUE.
  select value into v from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000441a01' and metric_code = 't441_rd'
     and as_of = date '2026-03-28';
  if v is distinct from 10 then
    raise exception 'R&D at 2026-03-28 is %, expected 10, Yahoo''s figure on SEC''s date', coalesce(v::text, '<none>');
  end if;
  select value into v from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000441a01' and metric_code = 't441_rd'
     and as_of = date '2026-01-03';
  if v is distinct from 20 then
    raise exception 'R&D at 2026-01-03 is %, expected 20: where SEC''s date is the LATER one it must still win', coalesce(v::text, '<none>');
  end if;

  -- 3. EACH METRIC'S VALUE IS STILL ITS OWN HIGHEST-PRIORITY ROW: SEC's revenue, not Yahoo's.
  select value into v from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000441a01' and metric_code = 't441_revenue'
     and as_of = date '2026-03-28';
  if v is distinct from 100 then
    raise exception 'revenue at 2026-03-28 is %, expected SEC''s 100 (Yahoo says 101)', coalesce(v::text, '<none>');
  end if;

  -- 4. THE DATE DOES NOT DEPEND ON WHAT IS ASKED FOR. Selecting R&D alone (by symbol, as the app
  --    reads) must not give Yahoo's dates back.
  select count(*) into n from market.security_metric_series
   where symbol = 'T441' and metric_code = 't441_rd'
     and as_of in (date '2025-12-31', date '2026-03-31');
  if n <> 0 then
    raise exception 'asked for R&D alone, % row(s) came back on Yahoo''s month ends — the date depends on the metric filter', n;
  end if;
  select as_of into d from market.security_metric_series
   where symbol = 'T441' and metric_code = 't441_rd' and value = 9;
  if d is distinct from date '2025-09-30' then
    raise exception 'the quarter only Yahoo reports is served at %, expected Yahoo''s own 2025-09-30', coalesce(d::text, '<none>');
  end if;

  -- 5. THE PERIOD END'S VALUE, NOT THE RESTATED OPENING BALANCE.
  select value into v from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000441a01' and metric_code = 't441_equity'
     and as_of = date '2024-12-31';
  if v is distinct from 500 then
    raise exception 'equity at 2024-12-31 is %, expected the period end''s 500. 480 is the next day''s restated opening balance', coalesce(v::text, '<none>');
  end if;

  raise notice 'ok  one period is one date across its metrics: the highest-priority source''s, where its rows sit';
end $$;

rollback;
