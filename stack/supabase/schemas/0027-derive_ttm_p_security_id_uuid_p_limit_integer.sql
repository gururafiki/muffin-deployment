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
