-- A TIME WINDOW IS NOT A SCOPE.
--
-- Migration 92 scoped the free-cash-flow and total-debt passes with
-- `where fetched_at > now() - interval '10 minutes'`, to stop them walking every metric row on
-- every call. It does stop that, and it replaces it with something almost as bad: right after a
-- drain, EVERY row is inside the window.
--
-- Measured in production immediately after the backlog reached 28:
--
--   {"resource":"security-metrics","written":576828,"pages":21,"remaining":28}
--
-- 576,828 upserts with 28 statements left to derive. The direct pass correctly found almost
-- nothing; the two derived passes re-processed the ~750,000 rows the previous run had just
-- written, because they had been written minutes ago. This resource is on a 10-minute cron, so
-- that is ~600k upserts and the WAL to match, every ten minutes, for ever — on a single
-- Always-Free node.
--
-- It also made `written` DISHONEST in the direction that matters: a number that looks like a lot
-- of work being done is exactly how a resource that is spinning stays invisible. `pages: 21` said
-- the same thing.
--
-- ── THE SCOPE IS THE PAGE, AND THE PAGE CAN NAME ITSELF ─────────────────────────────────────
--
-- The direct insert already knows precisely which (security, period) it touched — `returning` says
-- so. Capturing that and joining the derived passes to it is exact, needs no clock, and cannot
-- drift with how often the resource runs. A window was only ever an approximation of it.

create or replace function market.derive_security_metrics(p_limit integer default null)
returns integer
language plpgsql
as $$
declare
  v_written integer := 0;
  v_extra   integer := 0;
begin
  -- The rows this page actually wrote. `on commit drop` because the function is one transaction
  -- per call and a leftover temp table would silently scope the NEXT call.
  create temporary table _touched on commit drop as
  with src as (
    select st.security_id, st.period_ending, st.currency, st.source_code,
           coalesce(st.period_type, 'annual') as period_type,
           st.statement, st.data
      from market.security_statement st
     -- THE ANTI-JOIN THAT MAKES A PAGE ADVANCE — and it must be per STATEMENT KIND, not per
     -- (security, period). Migration 92's version asked "does this security have any metric for
     -- this period", and all three of a period's statements share that key: deriving the income
     -- statement therefore marked the balance sheet and cash flow done, for ever.
     --
     -- Production did not show it, by luck. The first drain ran against an empty table, so all
     -- three kinds sat in the same page and were derived together. It bites at every PAGE
     -- BOUNDARY (a period's statements straddling one), and whenever `security-statements`
     -- rewrites only some of a period's rows — which is exactly what SEC superseding yfinance
     -- does. A page of ONE reproduces it immediately, which is what the test uses.
     --
     -- `metric_source_field` is what says which metrics a statement kind can produce, so the
     -- question "has THIS statement been derived" is asked through it rather than invented.
     where not exists (
       select 1
         from market.security_metric sm
         join market.metric_source_field f2
           on f2.metric_code = sm.metric_code
          and f2.source_code = st.source_code
          and f2.statement   = st.statement
        where sm.security_id = st.security_id
          and sm.as_of       = st.period_ending
          and sm.fetched_at >= st.as_of)
     order by st.as_of
     limit p_limit
  ),
  ins as (
    insert into market.security_metric
      (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
    select
      src.security_id,
      f.metric_code,
      -- SEC says 'FY'; yfinance says nothing at all and its periods are annual — measured, median
      -- gap between consecutive periods 365 days (p25 365, p75 366, 1 of 299 gaps under 200).
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
    -- A NUMBER, NOT A NUMBER-LOOKING STRING. A provider sending "n/a" would raise and abort the
    -- whole statement, and migrations apply --single-transaction, so that is a failed deploy.
    where jsonb_typeof(src.data -> f.field) = 'number'
    on conflict (security_id, metric_code, period_type, as_of) do update
      set value = excluded.value,
          currency_code = excluded.currency_code,
          source_code = excluded.source_code,
          fetched_at = excluded.fetched_at
    returning security_id, period_type, as_of
  )
  select security_id, period_type, as_of from ins;

  get diagnostics v_written = row_count;

  -- Free cash flow where the provider does not report it. `abs()` because the capex SIGN differs
  -- by provider — yfinance negative (an outflow), SEC positive (a purchase) — and subtracting a
  -- negative reports free cash flow ABOVE operating cash flow.
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select ocf.security_id, 'free_cash_flow', ocf.period_type, ocf.as_of,
         ocf.value - abs(capex.value), ocf.currency_code, 'derived', now()
    from market.security_metric ocf
    -- SCOPED TO THIS PAGE, exactly. Not to a clock.
    join (select distinct security_id, period_type, as_of from _touched) t
      on t.security_id = ocf.security_id and t.period_type = ocf.period_type and t.as_of = ocf.as_of
    join market.security_metric capex
      on capex.security_id = ocf.security_id
     and capex.period_type = ocf.period_type
     and capex.as_of       = ocf.as_of
     and capex.metric_code = 'capital_expenditure'
   where ocf.metric_code = 'operating_cash_flow'
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
    join (select distinct security_id, period_type, as_of from _touched) t
      on t.security_id = ltd.security_id and t.period_type = ltd.period_type and t.as_of = ltd.as_of
    left join market.security_metric std
      on std.security_id = ltd.security_id
     and std.period_type = ltd.period_type
     and std.as_of       = ltd.as_of
     and std.metric_code = 'short_term_debt'
   where ltd.metric_code = 'long_term_debt'
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at;
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  drop table _touched;
  return v_written;
end;
$$;

comment on function market.derive_security_metrics(integer) is
  'Turns raw filing jsonb into the chartable series, one PAGE at a time. The source set is an anti-join over what is already derived, so a page advances and a re-fetched statement is re-derived; the derived passes join the page''s OWN rows rather than a time window, so a settled backlog does no work.';

revoke execute on function market.derive_security_metrics(integer) from public;
grant execute on function market.derive_security_metrics(integer) to service_role;

-- The backlog must ask the SAME question, per statement kind.
drop view if exists market.pending_metrics;

create view market.pending_metrics as
select st.security_id, st.statement, st.period_ending, st.source_code, st.as_of
  from market.security_statement st
 where not exists (
   select 1
     from market.security_metric sm
     join market.metric_source_field f2
       on f2.metric_code = sm.metric_code
      and f2.source_code = st.source_code
      and f2.statement   = st.statement
    where sm.security_id = st.security_id
      and sm.as_of       = st.period_ending
      and sm.fetched_at >= st.as_of);

comment on view market.pending_metrics is
  'Statement periods still to derive, per STATEMENT KIND: never derived, or re-fetched since. The SAME predicate the function pages over, so the count and the work cannot disagree. Settles to the statements whose provider reports none of the mapped lines — non-zero and stable is expected; the TREND is the signal.';

grant select on market.pending_metrics to service_role;

-- Supports the anti-join's metric-code lookup.
create index if not exists security_metric_code_idx
  on market.security_metric (security_id, as_of, metric_code, fetched_at desc);

notify pgrst, 'reload schema';
