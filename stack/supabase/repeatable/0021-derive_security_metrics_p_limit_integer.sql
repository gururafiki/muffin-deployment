CREATE OR REPLACE FUNCTION market.derive_security_metrics(p_limit integer DEFAULT NULL::integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare
  v_written integer := 0;
  v_extra   integer := 0;
begin
  -- The page, chosen by an INDEXED predicate. `derived_at is null` is served by
  -- `security_statement_underived_idx`; the NOT EXISTS this replaces had to be evaluated per row.
  create temporary table _src on commit drop as
  select st.security_id, st.statement, st.period_ending, st.currency, st.source_code,
         coalesce(st.period_type, 'annual') as period_type,
         st.data
    from market.security_statement st
   where st.derived_at is null
   order by st.as_of
   limit p_limit;

  create temporary table _touched on commit drop as
  with ins as (
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
    from _src src
    join market.metric_source_field f
      on f.source_code = src.source_code
     and f.statement   = src.statement
    where jsonb_typeof(src.data -> f.field) = 'number'
    on conflict (security_id, metric_code, period_type, as_of) do update
      set value = excluded.value,
          currency_code = excluded.currency_code,
          source_code = excluded.source_code,
          fetched_at = excluded.fetched_at
      -- A FILING BEATS A PROVIDER'S SUMMARY. Without this the resource that ran last wins and the
      -- served number depends on cron ordering — 17 years of XBRL quietly replaced by 4 periods of
      -- yfinance, with nothing to show for it but a shorter chart.
      where market.source_priority(excluded.source_code)
         >= market.source_priority(market.security_metric.source_code)
    returning security_id, period_type, as_of
  )
  select security_id, period_type, as_of from ins;

  get diagnostics v_written = row_count;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select ocf.security_id, 'free_cash_flow', ocf.period_type, ocf.as_of,
         ocf.value - abs(capex.value), ocf.currency_code, 'derived', now()
    from market.security_metric ocf
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
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

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
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  -- MARK WHAT WAS PROCESSED, keyed at the statement's own grain. Without this the page cannot
  -- advance and every call returns the same rows — the defect migration 92 exists to correct.
  update market.security_statement st
     set derived_at = now()
    from _src s
   where st.security_id    = s.security_id
     and st.statement      = s.statement
     and st.period_ending  = s.period_ending
     and st.period_type    = s.period_type;

  drop table _touched;
  drop table _src;
  return v_written;
end;
$function$;
