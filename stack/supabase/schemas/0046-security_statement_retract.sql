CREATE OR REPLACE FUNCTION market.security_statement_retract()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  with gone as (
    select g.security_id, g.source_code, g.statement, g.period_ending,
           case when lower(coalesce(g.period_type, 'annual')) in ('fy', 'annual') then 'annual'
                when lower(g.period_type) like 'q%' then 'quarter'
                else lower(g.period_type) end as metric_period_type
      from retracted g
  ),
  removed as (
    delete from market.security_metric m
     using gone g
      join market.metric_source_field f
        on f.source_code = g.source_code and f.statement = g.statement
     where m.security_id = g.security_id
       and m.source_code = g.source_code
       and m.metric_code = f.metric_code
       and m.period_type = g.metric_period_type
       and m.as_of       = g.period_ending
    returning m.security_id, m.metric_code, m.period_type, m.as_of
  ),
  stale_derived as (
    delete from market.security_metric d
     using removed r
     where d.security_id = r.security_id
       and d.period_type = r.period_type
       and d.as_of       = r.as_of
       and d.source_code = 'derived'
       and ((d.metric_code = 'free_cash_flow'
             and r.metric_code in ('operating_cash_flow', 'capital_expenditure'))
         or (d.metric_code = 'total_debt'
             and r.metric_code in ('long_term_debt', 'short_term_debt')))
    returning d.security_id
  ),
  requeued as (
    update market.security_statement st
       set derived_at = null
      from (select distinct security_id, period_type, as_of from removed) k
     where st.security_id   = k.security_id
       and st.period_ending = k.as_of
       and case when lower(coalesce(st.period_type, 'annual')) in ('fy', 'annual') then 'annual'
                when lower(st.period_type) like 'q%' then 'quarter'
                else lower(st.period_type) end = k.period_type
       and st.derived_at is not null
    returning st.security_id
  )
  delete from market.ttm_derivation t
   where t.security_id in (select security_id from removed
                           union select security_id from stale_derived
                           union select security_id from requeued);
  return null;
end;
$function$;
