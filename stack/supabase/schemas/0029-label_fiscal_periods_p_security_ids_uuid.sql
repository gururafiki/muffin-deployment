CREATE OR REPLACE FUNCTION market.label_fiscal_periods(p_security_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare v_labelled integer := 0;
begin
  with wanted as (
    select st.security_id, st.source_code, st.statement, st.period_ending, st.period_type,
           p.fiscal_year, p.fiscal_period
      from market.security_statement st
      left join lateral (
        select fp.fiscal_year, fp.fiscal_period
          from market.fiscal_period fp
         where fp.security_id = st.security_id
           and fp.is_canonical
           and fp.period_end between st.period_ending - 10 and st.period_ending + 10
           -- `FY` is the retired spelling of `annual` (2,259 rows until step 2b converts them).
           and fp.fiscal_period = any (case st.period_type
                                         when 'annual'  then array['FY']
                                         when 'FY'      then array['FY']
                                         when 'quarter' then array['Q1', 'Q2', 'Q3', 'Q4']
                                         when 'half'    then array['H1', 'H2']
                                       end)
         order by abs(fp.period_end - st.period_ending), fp.period_end desc
         limit 1) p on true
     where st.security_id = any (p_security_ids))
  update market.security_statement st
     set fiscal_year = w.fiscal_year,
         fiscal_period = w.fiscal_period
    from wanted w
   where st.security_id   = w.security_id
     and st.source_code   = w.source_code
     and st.statement     = w.statement
     and st.period_ending = w.period_ending
     and st.period_type   = w.period_type
     and (st.fiscal_year, st.fiscal_period) is distinct from (w.fiscal_year, w.fiscal_period);
  get diagnostics v_labelled = row_count;
  return v_labelled;
end;
$function$;
