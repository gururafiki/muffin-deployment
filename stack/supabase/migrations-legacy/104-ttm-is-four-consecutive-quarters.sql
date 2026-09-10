-- TTM: TRAILING TWELVE MONTHS, AND ONLY WHEN THERE ARE FOUR OF THEM.
--
-- financecharts' P/E page gives its architecture away: the table under the chart has columns
-- `DATE | DILUTED EPS TTM | ADJ close` with DAILY rows. They store a daily price and a stepwise
-- quarterly EPS TTM and compute the ratio per day — they do not store P/E. TTM is therefore the
-- missing input, not a nice-to-have: without it every ratio is either a stale annual figure or a
-- single quarter annualised.
--
-- ── A TTM IS A SUM OF FLOWS, AND A BALANCE SHEET IS NOT A FLOW ───────────────────────────────
--
-- Revenue over four quarters is a year's revenue. Total ASSETS over four quarters is four times
-- the company. So `metric.is_flow` marks which metrics may be summed, derived from the category
-- rather than hand-listed: income-statement and cash-flow lines accumulate, balance-sheet and
-- share-count metrics are instants and are given no TTM at all.
--
-- EPS is an income-statement line and therefore sums, which is exactly right — "diluted EPS TTM"
-- is the sum of four quarterly EPS figures, and it is the denominator financecharts charts.
--
-- ── EXACTLY FOUR, INSIDE 370 DAYS ───────────────────────────────────────────────────────────
--
-- The requirement is not "the last four rows". A company that has missed a filing, changed its
-- fiscal year, or whose Q2 was dropped as year-to-date (migration 103) will happily yield four
-- rows spanning two years — and their sum is a number that looks like a TTM and is not. Requiring
-- four quarters whose span is at most 370 days makes the gap visible as an ABSENCE rather than as
-- a plausible wrong figure, which is the choice this codebase keeps making and keeps being right
-- about.
--
-- 370 rather than 365: fiscal quarters drift, and a 4-4-5 retail calendar puts four quarters at up
-- to 371 days apart end-to-end. 370 admits the real ones and excludes a five-quarter window.

alter table market.metric add column if not exists is_flow boolean not null default false;

comment on column market.metric.is_flow is
  'True when the metric ACCUMULATES over a period and may be summed into a TTM — income-statement and cash-flow lines. False for instants: total assets over four quarters is four times the company, not a year of it.';

update market.metric
   set is_flow = (category in ('income_statement', 'cash_flow'));

-- ── the TTM pass ─────────────────────────────────────────────────────────────────────────────
create or replace function market.derive_ttm(p_security_id uuid default null)
returns integer
language plpgsql
as $$
declare v_written integer := 0;
begin
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select
    q.security_id,
    q.metric_code,
    'ttm',
    q.as_of,
    q.ttm_value,
    q.currency_code,
    'derived',
    now()
  from (
    select
      m.security_id,
      m.metric_code,
      m.as_of,
      m.currency_code,
      sum(m.value)   over w as ttm_value,
      count(*)       over w as quarters,
      min(m.as_of)   over w as window_start
    from market.security_metric m
    join market.metric mt on mt.code = m.metric_code and mt.is_flow
    where m.period_type = 'quarter'
      and (p_security_id is null or m.security_id = p_security_id)
    window w as (
      partition by m.security_id, m.metric_code
      order by m.as_of
      rows between 3 preceding and current row
    )
  ) q
  -- EXACTLY FOUR QUARTERS, INSIDE 370 DAYS. Four rows spanning two years sum to a number that
  -- looks like a TTM and is not; a missing quarter must read as no TTM, not as a smaller year.
  where q.quarters = 4
    and q.as_of - q.window_start <= 370
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value,
        currency_code = excluded.currency_code,
        fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);

  get diagnostics v_written = row_count;
  return v_written;
end;
$$;

comment on function market.derive_ttm(uuid) is
  'Trailing-twelve-month figures for FLOW metrics: the sum of exactly four quarters spanning at most 370 days. A company that missed a filing or changed its fiscal year yields four rows across two years, and their sum is a plausible wrong number — so the gap is left as an absence instead.';

revoke execute on function market.derive_ttm(uuid) from public;
grant execute on function market.derive_ttm(uuid) to service_role;

notify pgrst, 'reload schema';
