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
  select st.security_id, st.statement, st.period_ending,
         -- AN UNKNOWN CURRENCY IS WITHHELD, NOT A REASON TO STOP. `security_metric.currency_code`
         -- references `market.currency`, so one statement labelled with a code that table lacks
         -- failed the whole page, and every page after it, for every security.
         (select c.code from market.currency c where c.code = st.currency) as currency,
         st.source_code,
         coalesce(st.period_type, 'annual') as period_type,
         case when lower(coalesce(st.period_type, 'annual')) in ('fy', 'annual') then 'annual'
              when lower(st.period_type) like 'q%' then 'quarter'
              else lower(st.period_type) end as metric_period_type,
         st.fiscal_year,
         st.fiscal_period,
         st.as_of,
         st.data
    from market.security_statement st
   where st.derived_at is null
   order by st.as_of
   limit p_limit;

  create temporary table _touched on commit drop as
  with ins as (
    insert into market.security_metric
      (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at,
       fiscal_year, fiscal_period)
    -- ONE STATEMENT PER METRIC KEY (5 in the header): the best source, then the newest.
    select distinct on (src.security_id, f.metric_code, src.metric_period_type, src.period_ending)
      src.security_id,
      f.metric_code,
      src.metric_period_type,
      src.period_ending,
      (src.data ->> f.field)::numeric,
      src.currency,
      src.source_code,
      now(),
      src.fiscal_year,
      src.fiscal_period
    from _src src
    join market.metric_source_field f
      on f.source_code = src.source_code
     and f.statement   = src.statement
    where jsonb_typeof(src.data -> f.field) = 'number'
    order by src.security_id, f.metric_code, src.metric_period_type, src.period_ending,
             market.source_priority(src.source_code) desc, src.as_of desc, src.source_code
    on conflict (security_id, metric_code, period_type, as_of) do update
      set value = excluded.value,
          currency_code = excluded.currency_code,
          source_code = excluded.source_code,
          fetched_at = excluded.fetched_at,
          fiscal_year = excluded.fiscal_year,
          fiscal_period = excluded.fiscal_period
      -- A FILING BEATS A PROVIDER'S SUMMARY. Without this the resource that ran last wins and the
      -- served number depends on cron ordering — 17 years of XBRL quietly replaced by 4 periods of
      -- yfinance, with nothing to show for it but a shorter chart.
      where market.source_priority(excluded.source_code)
         >= market.source_priority(market.security_metric.source_code)
        and (market.security_metric.value, market.security_metric.currency_code,
             market.security_metric.source_code, market.security_metric.fiscal_year,
             market.security_metric.fiscal_period)
            is distinct from
            (excluded.value, excluded.currency_code, excluded.source_code, excluded.fiscal_year,
             excluded.fiscal_period)
    returning security_id, period_type, as_of
  )
  select security_id, period_type, as_of from ins;

  get diagnostics v_written = row_count;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at,
     fiscal_year, fiscal_period)
  select ocf.security_id, 'free_cash_flow', ocf.period_type, ocf.as_of,
         ocf.value - abs(capex.value), ocf.currency_code, 'derived', now(),
         ocf.fiscal_year, ocf.fiscal_period
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
    set value = excluded.value, currency_code = excluded.currency_code,
        source_code = excluded.source_code, fetched_at = excluded.fetched_at,
        fiscal_year = excluded.fiscal_year, fiscal_period = excluded.fiscal_period
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code)
      and (market.security_metric.value, market.security_metric.currency_code,
           market.security_metric.source_code, market.security_metric.fiscal_year,
           market.security_metric.fiscal_period)
          is distinct from
          (excluded.value, excluded.currency_code, excluded.source_code, excluded.fiscal_year,
           excluded.fiscal_period);
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at,
     fiscal_year, fiscal_period)
  select ltd.security_id, 'total_debt', ltd.period_type, ltd.as_of,
         ltd.value + coalesce(std.value, 0), ltd.currency_code, 'derived', now(),
         ltd.fiscal_year, ltd.fiscal_period
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
    set value = excluded.value, currency_code = excluded.currency_code,
        source_code = excluded.source_code, fetched_at = excluded.fetched_at,
        fiscal_year = excluded.fiscal_year, fiscal_period = excluded.fiscal_period
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code)
      and (market.security_metric.value, market.security_metric.currency_code,
           market.security_metric.source_code, market.security_metric.fiscal_year,
           market.security_metric.fiscal_period)
          is distinct from
          (excluded.value, excluded.currency_code, excluded.source_code, excluded.fiscal_year,
           excluded.fiscal_period);
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  -- MARK WHAT WAS PROCESSED, keyed at the statement's own grain. Without this the page cannot
  -- advance and every call returns the same rows — the defect migration 92 exists to correct.
  -- THE PROVIDER IS PART OF THE GRAIN: once two providers can hold one period, marking without it
  -- would mark the second done with only the first derived.
  update market.security_statement st
     set derived_at = now()
    from _src s
   where st.security_id    = s.security_id
     and st.source_code    = s.source_code
     and st.statement      = s.statement
     and st.period_ending  = s.period_ending
     and st.period_type    = s.period_type;

  drop table _touched;
  drop table _src;
  return v_written;
end;
$function$;
