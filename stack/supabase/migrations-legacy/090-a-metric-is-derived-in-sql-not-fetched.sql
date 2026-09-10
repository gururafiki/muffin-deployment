-- POPULATING `security_metric` NEEDS NO PROVIDER CALL — the data is already here.
--
-- Every other backlog in this pipeline is rate-limited by an upstream provider, which is why they
-- are edge functions with deadlines, batching, isolation and negative caches. This one is not:
-- `security_statement` already holds 105,927 periods of raw filing jsonb, and turning them into a
-- chartable series is a JOIN. Doing it in an edge function would inherit a 90-second worker limit
-- and a 256 MB ceiling to solve a problem that has neither.
--
-- So it is a SQL function, called by a resource that does nothing else. The consequences worth
-- stating: it cannot be throttled, it cannot half-fail across a batch, and re-running it is free.
--
-- ── WHY THE MAPPING IS JOINED, NOT INLINED ───────────────────────────────────────────────────
--
-- `metric_source_field` (migration 89) exists because sec and yfinance share 4 of 40
-- income-statement field names. This function therefore never names a provider field: it joins the
-- catalogue on the statement's OWN `source_code`, so the same row is read correctly whichever
-- provider wrote it, and a third provider is a row rather than a branch here.
--
-- ── CURRENCY: THE FACT, NOT THE GUESS ────────────────────────────────────────────────────────
--
-- `currency_code` is `st.currency` and NOTHING ELSE. It is null for every yfinance period, which
-- is honest: yfinance does not say. Falling back to `security.currency_code` would be substituting
-- the QUOTE currency for the REPORTING currency — precisely how Alibaba's CNY revenue rendered as
-- "$1.02T". The gate that decides when a quote currency may stand in for a reporting one already
-- exists in `security_statement_current`, and duplicating it here would be the same rule in two
-- places, which this codebase has watched drift before.
--
-- ── DERIVED METRICS ARE COMPUTED FROM METRICS, NOT FROM FIELDS ───────────────────────────────
--
-- Free cash flow is reported by yfinance and absent from SEC; total debt by neither. Both are
-- computed from metrics already written in the same pass, so they are provider-independent by
-- construction and carry `source_code` of the statement they came from. Capital expenditure's SIGN
-- differs by provider (yfinance sends it negative, SEC positive), so the derivation uses
-- `abs()` — measured, not assumed, and asserted in the behaviour test.

-- A COMPUTED ROW SAYS SO. Steps 2 and 3 below write `source_code = 'derived'` rather than the
-- provenance of the statement they were computed from, because `metric.is_derived` cannot answer
-- the question that matters per row: free cash flow is REPORTED by yfinance and COMPUTED for SEC,
-- so the flag on the catalogue is "sometimes computed" and only the row can say which this is.
-- It is also what makes step 2 idempotent — without a distinguishable marker, a re-run cannot tell
-- its own output from a provider's figure.
insert into market.data_source (code, name, priority) values
  ('derived', 'Computed from other metrics', 50)
on conflict (code) do nothing;

create or replace function market.derive_security_metrics(p_limit integer default null)
returns integer
language plpgsql
as $$
declare
  v_written integer := 0;
  v_extra   integer := 0;
begin
  -- ── 1. every directly-mapped metric ────────────────────────────────────────────────────────
  with src as (
    select st.security_id, st.period_ending, st.currency, st.source_code,
           coalesce(st.period_type, 'annual') as period_type,
           st.statement, st.data
      from market.security_statement st
     order by st.security_id, st.period_ending desc
     limit p_limit
  )
  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select
    src.security_id,
    f.metric_code,
    -- The provider's own label, normalised. SEC says 'FY'; yfinance says 'annual' or nothing.
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
  -- A NUMBER, NOT A NUMBER-LOOKING STRING. `jsonb_typeof` gates the cast because a provider that
  -- sends "n/a" would raise and abort the whole statement — and migrations apply
  -- `--single-transaction`, so that is a failed deploy rather than a skipped row.
  where jsonb_typeof(src.data -> f.field) = 'number'
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value,
        currency_code = excluded.currency_code,
        source_code = excluded.source_code,
        fetched_at = excluded.fetched_at;
  get diagnostics v_written = row_count;

  -- ── 2. free cash flow, where the provider does not report it ───────────────────────────────
  -- Operating cash flow minus capital expenditure. `abs()` because the SIGN of capex differs by
  -- provider: yfinance sends it negative (a cash outflow), SEC positive (a purchase). Subtracting
  -- a negative would ADD the capex and report free cash flow above operating cash flow.
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
     -- Only where the provider did not report it. yfinance's own figure is authoritative.
     and not exists (
       select 1 from market.security_metric x
        where x.security_id = ocf.security_id and x.period_type = ocf.period_type
          and x.as_of = ocf.as_of and x.metric_code = 'free_cash_flow'
          and x.source_code <> 'derived')
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at;
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  -- ── 3. total debt, which neither provider reports ──────────────────────────────────────────
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
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at;
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  return v_written;
end;
$$;

comment on function market.derive_security_metrics(integer) is
  'Turns raw filing jsonb into the chartable series. Joins market.metric_source_field on the statement''s OWN source_code, so it never names a provider field and a third provider is a row. Needs no provider call, so it cannot be throttled and re-running it is free.';

-- DROP-THEN-CREATE, because `create or replace function` PRESERVES the existing ACL and a grant in
-- a re-run migration can therefore only ever ADD a privilege — a line tightening permissions
-- applies cleanly, reports success and changes nothing. The revoke is what makes the grant
-- load-bearing: Postgres grants execute to PUBLIC by default.
revoke execute on function market.derive_security_metrics(integer) from public;
grant execute on function market.derive_security_metrics(integer) to service_role;

-- ── the serving view ─────────────────────────────────────────────────────────────────────────
drop view if exists market.security_metric_series;

create view market.security_metric_series as
select
  sym.symbol,
  sm.security_id,
  sm.metric_code,
  m.name    as metric_name,
  m.category,
  m.unit,
  m.is_derived,
  sm.period_type,
  sm.as_of,
  sm.value,
  sm.currency_code,
  sm.source_code
from market.security_metric sm
join market.metric m          on m.code = sm.metric_code
join market.security_symbol sym on sym.security_id = sm.security_id;

comment on view market.security_metric_series is
  'One security''s metric history, ready to chart. `currency_code` is the REPORTING currency from the filing and is null where the provider did not say — an unlabelled figure, never a guessed one.';

grant select on market.security_metric_series to anon, authenticated, service_role;

-- ── the backlog: statements that produced NOTHING ────────────────────────────────────────────
--
-- Not "statements not yet derived" — this function is idempotent and re-derives everything every
-- run, so a queue of pending work would always be empty and tell nobody anything. What is worth
-- counting is the opposite: a statement period that yielded NO metric at all. That means the
-- catalogue's field names no longer match what the provider sends, which is otherwise completely
-- silent — a missing field is simply no row, and the chart is merely shorter.
--
-- Expected to be non-zero and STABLE: a statement whose provider genuinely reported none of the
-- mapped lines (a shell company, a fund) will sit here for ever and should. It is the TREND that
-- is the signal, which is why it is a count rather than a work queue.
drop view if exists market.pending_metrics;

create view market.pending_metrics as
select st.security_id, st.statement, st.period_ending, st.source_code
  from market.security_statement st
 where not exists (
   select 1 from market.security_metric sm
    where sm.security_id = st.security_id
      and sm.as_of = st.period_ending);

comment on view market.pending_metrics is
  'Statement periods that produced NO metric — the catalogue''s field names drifting from what a provider sends, which is otherwise silent. Expected non-zero and stable; the TREND is the signal.';

grant select on market.pending_metrics to service_role;

notify pgrst, 'reload schema';
