-- A 52/53-WEEK QUARTER TAKES ITS LABEL FROM A MONTH-END DATE.
--
-- `label_fiscal_periods` labels a statement row with the nearest canonical fiscal period of its
-- class within 10 days. Yahoo dates a quarter by its month end, and a 52/53-week filer's SEC quarter
-- ends on a Saturday or Sunday: Costco's Q2 FY2025 ended 2025-02-16 and Yahoo dates it 2025-02-28.
-- Measured on production 2026-11-08: 47 Yahoo quarters across ten retailers (COST, PEP, KR, AZO,
-- DPZ, ACI, AAP, CAVA, FLO, JACK) sit 11-25 days from their SEC quarter, so they stay unlabelled and
-- the statement table shows each of them twice: SEC's labelled row and Yahoo's unlabelled one. The
-- next rows out, at 30-31 days (Greif, FedEx, Cardlytics, four annuals), are genuinely different
-- periods, such as Greif's year-end change.
--
-- The user approved the rule on 2026-11-08:
--   * QUARTERS ONLY, and only where the SEC calendar's regime is 52/53-week, the window is 25 days.
--     Consecutive quarters are at least 84 days apart, so 25 cannot reach the next one. Annual and
--     half-year rows, and every other calendar, keep 10.
--   * THE NEAREST ROW WINS for a match beyond 10 days. Yahoo holds two dates for one quarter on a
--     few companies (CAVA's Q1 2026 ended 04-19; Yahoo has 03-31 and 04-30), and both would
--     otherwise take the label. Only the nearer one of a source's rows does; the other stays
--     unlabelled. A match within 10 days keeps its label exactly as before.
--
-- `create or replace function` keeps the function's ACL. A label change re-queues the row for the
-- metric derivation (the update trigger), so the metrics follow.

create or replace function market.label_fiscal_periods(p_security_ids uuid[])
 returns integer
 language plpgsql
as $function$
declare v_labelled integer := 0;
begin
  with matched as (
    select st.security_id, st.source_code, st.statement, st.period_ending, st.period_type,
           p.fiscal_year, p.fiscal_period, p.distance
      from market.security_statement st
      left join lateral (
        select fp.fiscal_year, fp.fiscal_period, abs(fp.period_end - st.period_ending) as distance
          from market.fiscal_period fp
          join market.fiscal_calendar fc on fc.security_id = fp.security_id and fc.regime = fp.regime
         where fp.security_id = st.security_id
           and fp.is_canonical
           -- The widest window, so the period index serves the range; the rule narrows it below.
           and fp.period_end between st.period_ending - 25 and st.period_ending + 25
           and abs(fp.period_end - st.period_ending)
               <= case when st.period_type = 'quarter' and fc.is_52_53_week then 25 else 10 end
           -- `FY` is the retired spelling of `annual` (2,259 rows until step 2b converts them).
           and fp.fiscal_period = any (case st.period_type
                                         when 'annual'  then array['FY']
                                         when 'FY'      then array['FY']
                                         when 'quarter' then array['Q1', 'Q2', 'Q3', 'Q4']
                                         when 'half'    then array['H1', 'H2']
                                       end)
         order by abs(fp.period_end - st.period_ending), fp.period_end desc
         limit 1) p on true
     where st.security_id = any (p_security_ids)),
  ranked as (
    select m.*,
           row_number() over (
             partition by m.security_id, m.source_code, m.statement, m.period_type,
                          m.fiscal_year, m.fiscal_period
             order by m.distance, m.period_ending desc) as nearest
      from matched m),
  wanted as (
    select r.security_id, r.source_code, r.statement, r.period_ending, r.period_type,
           case when r.distance <= 10 or r.nearest = 1 then r.fiscal_year end as fiscal_year,
           case when r.distance <= 10 or r.nearest = 1 then r.fiscal_period end as fiscal_period
      from ranked r)
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

-- ONCE, for every company with a 52/53-week calendar, so the existing rows take the rule now rather
-- than at each company's next visit (up to a week). Dry-run on production in a rolled-back
-- transaction, 2026-11-08: 106 Yahoo quarterly statement rows gained a label across the ten
-- retailers above, none lost or changed one, in 3.2 s for 277 companies. The label change re-queues
-- them, and the derivation's half-hourly floor relabels their metrics.
select market.label_fiscal_periods(
  array(select distinct security_id from market.fiscal_calendar where is_52_53_week));
