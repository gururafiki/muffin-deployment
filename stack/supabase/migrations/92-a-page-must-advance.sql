-- A PAGE THAT DOES NOT ADVANCE IS NOT A PAGE.
--
-- Migration 90 shipped `derive_security_metrics(p_limit)` selecting
-- `... order by st.security_id, st.period_ending desc limit p_limit`. That is the SAME first N
-- statement rows on every call. Measured in production immediately after deploying it, two
-- identical invocations:
--
--   {"resource":"security-metrics","written":7386,"remaining":104925}
--   {"resource":"security-metrics","written":7386,"remaining":104925}
--
-- Byte-identical. It reports 7,386 rows of progress and does the same work for ever, which is the
-- exact shape `pending_industry` had when it re-fetched the same top-300 by weight on every run
-- since migration 23 and never reached row 301. The tell is the same too: a number that looks like
-- throughput and never changes.
--
-- Unlimited it does not work either — 105,927 statements exceeded the statement timeout on the
-- role PostgREST uses, so the resource answered `ok: false` with
-- `canceling statement due to statement timeout`. Correctly reported, and still no work done.
--
-- ── THE SOURCE SET IS AN ANTI-JOIN OVER WHAT IS ALREADY DERIVED ─────────────────────────────
--
-- A statement needs deriving when nothing has been derived from it, OR when it has been RE-FETCHED
-- since it was (`security-statements` rewrites the row with a fresh `as_of` when SEC supersedes
-- yfinance, which is happening across the whole universe right now). One condition covers both:
-- no metric for that (security, period) whose `fetched_at` is at least as new as the statement.
--
-- That makes each page advance AND lets a corrected filing propagate — the two properties that
-- would otherwise pull in opposite directions. It also means `pending_metrics` and the work done
-- are THE SAME predicate rather than two descriptions of it that can disagree.

-- Supports the anti-join. `security_metric_series_idx` leads on `security_id` but carries
-- `metric_code` next, so a lookup on (security_id, as_of) cannot use it beyond the first column.
create index if not exists security_metric_period_idx
  on market.security_metric (security_id, as_of, fetched_at desc);

create or replace function market.derive_security_metrics(p_limit integer default null)
returns integer
language plpgsql
as $$
declare
  v_written integer := 0;
  v_extra   integer := 0;
begin
  with src as (
    select st.security_id, st.period_ending, st.currency, st.source_code,
           coalesce(st.period_type, 'annual') as period_type,
           st.statement, st.data
      from market.security_statement st
     -- THE ANTI-JOIN THAT MAKES A PAGE ADVANCE. Without it this selected the same first N rows on
     -- every call and reported the same `written` for ever.
     where not exists (
       select 1 from market.security_metric sm
        where sm.security_id = st.security_id
          and sm.as_of       = st.period_ending
          and sm.fetched_at >= st.as_of)
     -- Oldest first, so a page cannot be starved by rows that keep arriving.
     order by st.as_of
     limit p_limit
  )
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select
    src.security_id,
    f.metric_code,
    case when lower(src.period_type) in ('fy', 'annual') then 'annual'
         when lower(src.period_type) like 'q%'           then 'quarter'
         else lower(src.period_type) end,
    src.period_ending,
    (src.data ->> f.field)::numeric,
    src.currency,
    src.source_code,
    now()
  from src
  join market.metric_source_field f
    on f.source_code = src.source_code
   and f.statement   = src.statement
  where jsonb_typeof(src.data -> f.field) = 'number'
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value,
        currency_code = excluded.currency_code,
        source_code = excluded.source_code,
        fetched_at = excluded.fetched_at;
  get diagnostics v_written = row_count;

  -- Free cash flow where the provider does not report it. `abs()` because the capex SIGN differs
  -- by provider — yfinance negative (an outflow), SEC positive (a purchase) — and subtracting a
  -- negative reports free cash flow ABOVE operating cash flow.
  --
  -- Scoped to what this page just touched. Unscoped it walked every metric row on every call,
  -- which is most of what made the unlimited run exceed the statement timeout.
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select ocf.security_id, 'free_cash_flow', ocf.period_type, ocf.as_of,
         ocf.value - abs(capex.value), ocf.currency_code, 'derived', now()
    from market.security_metric ocf
    join market.security_metric capex
      on capex.security_id = ocf.security_id
     and capex.period_type = ocf.period_type
     and capex.as_of       = ocf.as_of
     and capex.metric_code = 'capital_expenditure'
   where ocf.metric_code = 'operating_cash_flow'
     and ocf.fetched_at > now() - interval '10 minutes'
     and not exists (
       select 1 from market.security_metric x
        where x.security_id = ocf.security_id and x.period_type = ocf.period_type
          and x.as_of = ocf.as_of and x.metric_code = 'free_cash_flow'
          and x.source_code <> 'derived')
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at;
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  -- Total debt, which neither provider reports.
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select ltd.security_id, 'total_debt', ltd.period_type, ltd.as_of,
         ltd.value + coalesce(std.value, 0), ltd.currency_code, 'derived', now()
    from market.security_metric ltd
    left join market.security_metric std
      on std.security_id = ltd.security_id
     and std.period_type = ltd.period_type
     and std.as_of       = ltd.as_of
     and std.metric_code = 'short_term_debt'
   where ltd.metric_code = 'long_term_debt'
     and ltd.fetched_at > now() - interval '10 minutes'
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at;
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  return v_written;
end;
$$;

comment on function market.derive_security_metrics(integer) is
  'Turns raw filing jsonb into the chartable series, one PAGE at a time. The source set is an anti-join over what is already derived, so a page advances and a re-fetched statement is re-derived; the derived-metric passes are scoped to what the page touched rather than the whole table.';

revoke execute on function market.derive_security_metrics(integer) from public;
grant execute on function market.derive_security_metrics(integer) to service_role;

-- THE BACKLOG AND THE WORK ARE NOW THE SAME PREDICATE. The old view asked "has no metric at all",
-- which would report a re-fetched statement as done while the function still had it queued —
-- two descriptions of one thing, free to disagree.
drop view if exists market.pending_metrics;

create view market.pending_metrics as
select st.security_id, st.statement, st.period_ending, st.source_code, st.as_of
  from market.security_statement st
 where not exists (
   select 1 from market.security_metric sm
    where sm.security_id = st.security_id
      and sm.as_of       = st.period_ending
      and sm.fetched_at >= st.as_of);

comment on view market.pending_metrics is
  'Statement periods still to derive: never derived, or re-fetched since. The SAME predicate the function pages over, so the count and the work cannot disagree. Settles to the periods whose provider reports none of the mapped lines — non-zero and stable is expected; the TREND is the signal.';

grant select on market.pending_metrics to service_role;

notify pgrst, 'reload schema';
