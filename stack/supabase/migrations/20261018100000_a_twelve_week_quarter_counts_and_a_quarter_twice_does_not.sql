-- A TWELVE-WEEK QUARTER COUNTS, AND A QUARTER TWICE DOES NOT: TWO DEFECTS IN WHICH QUARTERS A TTM
-- SUMS, FOUND BY THE COMPANY LANE'S FIRST CHECK-IN (2026-10-18).
--
-- 1. A 12/12/12/16-WEEK YEAR GOT NO FOURTH QUARTER, SO NO TTM. `derive_ttm` derives SEC's missing
--    fiscal Q4 as the year less Q1-Q3, only when the three sit where a 13-week calendar puts them:
--    Q1 to Q3 170-200 days, Q3 to the year end 80-100. Costco, PepsiCo, AutoZone and Domino's file
--    12/12/12/16 weeks: Q1 to Q3 is 168 days, Q3 to the year end 112 (119 in a 53-week year). Both
--    bounds refused it, so these companies have had no TTM since migration 20261010210000.
--    * MEASURED. Of the annual eps_diluted rows since 2023 with three same-source quarters and no
--      stated Q4, every gap shape derives except 112/168 (10 years) and 119/168 (2): AZO, COST, DPZ
--      and PEP. Costco's P/E stood on its fiscal-year EPS, 18.21 (`eps_basis = annual`), all year.
--    * EVERY YEAR THE NEW BOUNDS ADMIT WAS READ, over all flow metrics and years: 18 securities.
--      12/12/12/16 calendars throughout (AZO, COST, DPZ, PEP) or historically (MAR, VAC, WWW, YUM),
--      hotel REITs whose 16-week Q4 runs to 31 December (HST, DRH: 111-115 days), and dividends
--      paid dated on payment days (PKG, UMH, GTX, ASC), whose derived Q4 matches their other
--      quarters (PKG 95.0 beside 94.8, 95.0, 95.0). AROC, MSI and FLOC imply a negative Q4 from
--      non-negative inputs, which the existing guard refuses.
--    * THE FIX: Q3 to the year end 80-120 days, Q1 to Q3 165-200. Within the 300-day window that
--      still refuses three quarters that do not tile the year, such as an old calendar's Q1-Q3
--      before a year on a new one (Q3 to the year end 61 days).
--    * RUN AGAINST PRODUCTION'S ROWS AND ROLLED BACK: rows only added (COST 888, PEP 764, AZO 755,
--      DPZ 716), none changed; Costco's Q4 FY2025 EPS 5.87 and AutoZone's 48.70, as filed. P/E on
--      the newest bar: COST 54.32 -> 49.75 (TTM EPS 19.88), PEP 21.92 -> 17.23 (7.63).
--
-- 2. A QUARTER COUNTED TWICE WITH ANOTHER MISSING STILL SPANS A YEAR. The window refuses 240-300
--    days only, so one quarter under two dates plus one quarter absent passes: YUM's 2016 Q1 is
--    filed as 03-19 and again as 03-31, and the old TTM at 2016-03-31 was Q2 + Q3 + both Q1s. SEC
--    re-dates a 52/53-week quarter (ATI 2023-09-30 and 10-01, TRNS 2025-09-27 and 09-30), and a
--    fiscal-year change overlaps two calendars (Greif 2025-06-30 and 07-31, from Yahoo).
--    * MEASURED over every accepted window of every flow metric (1,004,396). By smallest gap
--      between consecutive quarters: 0-32 days 783 windows, 33-44 days 14 (all dividends dated on
--      payment days), 45-54 days 4, 55-64 days 198, 75 and over 1,003,389. Nothing under 33 days
--      can be two consecutive quarters. 55-64 mixes genuine years (Jack in the Box: a 12-week
--      quarter Yahoo dates 59 days after the one before) with fiscal-year changes, so it is kept.
--    * THE FIX: refuse a window holding two quarters under 45 days apart. 797 windows in 109
--      securities; 42 are a newest TTM, among them Greif's EPS (7.845, its 2025 summer quarter
--      counted twice) and TRNS's revenue. A refused window publishes nothing; the ratio view then
--      falls back to the fiscal year and says so.
--
-- RE-QUEUED. `pending_ttm` re-asks a security only when a newer input arrives, so the securities
-- holding a year the new Q4 bounds admit, or two quarters under 45 days apart, are queued
-- explicitly (18 and 224 on production). The migration runs once.
--
-- Signature unchanged, so `create or replace` keeps the grants. Guarded by the sixth and seventh
-- blocks of tests/a-ttm-needs-four-real-quarters.sql.

CREATE OR REPLACE FUNCTION market.derive_ttm(p_security_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 400)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare v_written integer := 0;
begin
  -- THE PAGE, CHOSEN ONCE, so the marker records exactly the securities evaluated. One named
  -- security, or up to `p_limit` from the backlog, which is an anti-join over the marker and so
  -- advances whether or not a page produced anything.
  create temporary table _ttm_page on commit drop as
  select p.security_id from market.pending_ttm p
   where p_security_id is null
   limit p_limit;
  if p_security_id is not null then
    insert into _ttm_page (security_id) values (p_security_id);
  end if;

  -- 1. THE FISCAL FOURTH QUARTER: the year less its three discrete quarters, same source and
  --    currency, consecutive (Q1 to Q3 165-200 days, Q3 to the year end 80-120). The bounds
  --    admit 13-week quarters (182/91, a 53-week year 182/98 or 189/91) and the 12/12/12/16-week
  --    calendar (168/112, a 53-week year 168/119) that Costco and PepsiCo file.
  create temporary table _q4 on commit drop as
  select a.security_id, a.metric_code, a.as_of, a.value - q.s3 as value, a.currency_code
    from market.security_metric a
    join market.metric mt on mt.code = a.metric_code and mt.is_flow
    join _ttm_page pg on pg.security_id = a.security_id
   cross join lateral (
     select count(*) as n, sum(m.value) as s3, min(m.as_of) as first_q, max(m.as_of) as last_q,
            bool_and(m.value >= 0) as nonneg,
            -- Two unknown currencies are not a match: a null on either side fails this.
            bool_and(m.currency_code = a.currency_code) as same_ccy
       from market.security_metric m
      where m.security_id = a.security_id
        and m.metric_code = a.metric_code
        and m.period_type = 'quarter'
        and m.source_code = a.source_code
        and m.as_of > a.as_of - 300
        and m.as_of < a.as_of) q
   where a.period_type = 'annual'
     and q.n = 3
     and a.as_of - q.last_q between 80 and 120
     and q.last_q - q.first_q between 165 and 200
     and q.same_ccy
     and not (q.nonneg and a.value >= 0 and a.value - q.s3 < 0)
     and not exists (
       select 1 from market.security_metric x
        where x.security_id = a.security_id and x.metric_code = a.metric_code
          and x.period_type = 'quarter' and x.source_code <> 'derived-q4'
          and x.as_of between a.as_of - 10 and a.as_of + 10);

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select security_id, metric_code, 'quarter', as_of, value, currency_code, 'derived-q4', now()
    from _q4
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value,
        currency_code = excluded.currency_code,
        fetched_at = excluded.fetched_at
    where market.security_metric.source_code = 'derived-q4'
      and (market.security_metric.value, market.security_metric.currency_code)
          is distinct from (excluded.value, excluded.currency_code);

  delete from market.security_metric m
   using _ttm_page pg
   where m.security_id = pg.security_id
     and m.period_type = 'quarter'
     and m.source_code = 'derived-q4'
     and not exists (select 1 from _q4 q
                      where q.security_id = m.security_id and q.metric_code = m.metric_code
                        and q.as_of = m.as_of);

  -- 2. THE TTM: FOUR CONSECUTIVE QUARTERS OF A FLOW, IN ONE CURRENCY. 240-300 days from the first
  --    quarter's end to the last: above it a quarter is missing, below it one is in twice.
  --    A QUARTER TWO SOURCES REPORT IS ONE QUARTER. SEC dates a quarter by its last day and Yahoo by
  --    the month end, so a 52/53-week filer's quarters arrive twice, days apart, and the window
  --    would refuse every year. Within ten days of each other the higher-priority source's row
  --    stands for the quarter (the later date on a tie), the same ten days step 1 uses.
  --    AND NO QUARTER IS IN A WINDOW TWICE. Two rows under 45 days apart (half a quarter) are one
  --    quarter under two dates, or two overlapping quarters after a fiscal-year change. With a
  --    quarter missing elsewhere the span still reads as a year, so the span alone cannot see it.
  --    A 12-week quarter dated by the month end reads as short as ~54 days, and is kept.
  create temporary table _ttm on commit drop as
  select q.security_id, q.metric_code, q.as_of, q.ttm_value, q.currency_code
    from (
      select m.security_id, m.metric_code, m.as_of, m.currency_code,
             sum(m.value)         over w as ttm_value,
             count(*)             over w as quarters,
             min(m.as_of)         over w as window_start,
             min(m.currency_code) over w as min_ccy,
             max(m.currency_code) over w as max_ccy,
             min(m.gap)           over g as min_gap
        from (
          select m.security_id, m.metric_code, m.as_of, m.value, m.currency_code,
                 m.as_of - lag(m.as_of) over (partition by m.security_id, m.metric_code
                                              order by m.as_of) as gap
            from market.security_metric m
            join market.metric mt on mt.code = m.metric_code and mt.is_flow
            join _ttm_page pg on pg.security_id = m.security_id
           where m.period_type = 'quarter'
             and not exists (
                   select 1 from market.security_metric o
                    where o.security_id = m.security_id and o.metric_code = m.metric_code
                      and o.period_type = 'quarter'
                      and o.as_of between m.as_of - 10 and m.as_of + 10
                      and o.source_code <> m.source_code
                      and (market.source_priority(o.source_code), o.as_of)
                        > (market.source_priority(m.source_code), m.as_of))) m
      -- `g` is the window's three gaps: each row's gap is to the row before it.
      window w as (partition by m.security_id, m.metric_code
                   order by m.as_of rows between 3 preceding and current row),
             g as (partition by m.security_id, m.metric_code
                   order by m.as_of rows between 2 preceding and current row)
    ) q
   where q.quarters = 4
     and q.as_of - q.window_start between 240 and 300
     and q.min_gap >= 45
     and q.min_ccy is not distinct from q.max_ccy;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select security_id, metric_code, 'ttm', as_of, ttm_value, currency_code, 'derived', now()
    from _ttm
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value,
        currency_code = excluded.currency_code,
        fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code)
      and (market.security_metric.value, market.security_metric.currency_code)
          is distinct from (excluded.value, excluded.currency_code);

  get diagnostics v_written = row_count;

  -- 3. RETRACT WHAT THE RULE NO LONGER PRODUCES, for the securities it evaluated.
  delete from market.security_metric m
   using _ttm_page pg
   where m.security_id = pg.security_id
     and m.period_type = 'ttm'
     and m.source_code = 'derived'
     and not exists (select 1 from _ttm t
                      where t.security_id = m.security_id and t.metric_code = m.metric_code
                        and t.as_of = m.as_of);

  -- 4. EVALUATED, WHATEVER IT FOUND.
  insert into market.ttm_derivation (security_id, derived_at)
  select security_id, now() from _ttm_page
  on conflict (security_id) do update set derived_at = excluded.derived_at;

  drop table _ttm;
  drop table _q4;
  drop table _ttm_page;
  return v_written;
end;
$function$;
delete from market.ttm_derivation d
 where exists (
         select 1 from market.security_metric a
           join market.metric mt on mt.code = a.metric_code and mt.is_flow
          cross join lateral (
            select count(*) as n, min(m.as_of) as first_q, max(m.as_of) as last_q
              from market.security_metric m
             where m.security_id = a.security_id and m.metric_code = a.metric_code
               and m.period_type = 'quarter' and m.source_code = a.source_code
               and m.as_of > a.as_of - 300 and m.as_of < a.as_of) q
          where a.security_id = d.security_id and a.period_type = 'annual' and q.n = 3
            and a.as_of - q.last_q between 80 and 120 and q.last_q - q.first_q between 165 and 200
            and not (a.as_of - q.last_q between 80 and 100
                     and q.last_q - q.first_q between 170 and 200))
    or exists (
         select 1 from market.security_metric m
           join market.metric mt on mt.code = m.metric_code and mt.is_flow
           join market.security_metric o
             on o.security_id = m.security_id and o.metric_code = m.metric_code
            and o.period_type = 'quarter'
            and o.as_of > m.as_of and o.as_of < m.as_of + 45
            -- a pair the ten-day rule does not already make one quarter
            and (o.source_code = m.source_code or o.as_of > m.as_of + 10)
          where m.security_id = d.security_id and m.period_type = 'quarter');
