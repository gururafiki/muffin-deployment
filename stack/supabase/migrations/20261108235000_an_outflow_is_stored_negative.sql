-- AN OUTFLOW IS STORED NEGATIVE, WHOEVER STATED IT.
--
-- Three cash-flow metrics carried opposite signs by provider. Measured 2026-11-08, share of rows
-- above zero:
--                          SEC company facts            Yahoo
--   capital_expenditure    0.98 of 115,271 rows         0.00 of 80,604
--   buyback                0.74 of  78,324              0.01 of 30,812
--   dividends_paid         0.94 of  81,221              0.01 of 61,511
-- SEC tags these as payments (`PaymentsToAcquirePropertyPlantAndEquipment`, `PaymentsForRepurchase
-- OfCommonStock`, `PaymentsOfDividends`), positive. Yahoo, and openbb's old `sec` rows, state them as
-- a cash-flow statement does, negative. Every other cash-flow metric agrees across providers. Since
-- the SEC history loaded on 2026-11-07, company facts are the preferred source for ~3,700 filers, so
-- the statement table showed capex positive for them and negative for every other company, and the
-- p50 of all three flipped sign overnight (the unit-flip alert, 2026-11-07 03:06).
--
-- DECIDED by the user on 2026-11-08: outflows negative, as a cash-flow statement presents them and as
-- the app showed for every company before 11-07.
--
-- WHERE THE SIGN LIVES:
--   * `metric_source_field.sign` — how a provider states a metric relative to the metric's own sign.
--     -1 for company facts' three payments (`sec-xbrl`, and `sec-xbrl-ytd`, computed from them);
--     1 everywhere else, `sec` included (openbb already states them negative). The derivation
--     multiplies, so a filer that tagged a payment negative reads as an inflow, which is what it
--     stated; `-abs()` would hide that.
--   * `metric.is_outflow` — the metric's own convention, which the fourth-quarter guard reads.
--     Without it the guard ("a non-negative series cannot leave a negative remainder", 806 fiscal
--     years at 2026-10-10) would stop applying to capex the moment it is stored negative, and a
--     blanket mirror for every metric would refuse a loss-making company's profitable Q4.
-- Free cash flow is unaffected: it is `operating cash flow - abs(capex)` and stays so.
--
-- THE REPAIR mirrors what a re-derivation now produces, in one transaction. Every company-facts row
-- of the three metrics is the statement's number (`check_derived_metrics` asserts it exactly), so
-- the new number is its negation. Negating in place, rather than re-queueing 192,371 cash
-- statements, leaves no hour in which half a company's years are flipped, and it also reaches 3,356
-- rows the edge's `security-xbrl` wrote with no statement behind them, which no re-derivation can.
-- `fetched_at` moves with the value, which re-lists the security in `pending_ttm`, so the TTMs and the
-- derived fourth quarters are recomputed by the next derivation run.
--
-- MEASURED ON PRODUCTION, rolled back, 2026-11-08: the repair rewrote 249,501 rows in 117.6 s
-- (`fetched_at` is in two of the table's six indexes, so no update is HOT). Afterwards all 271,437
-- statement-backed rows equal sign x statement, 0 differ, and `pending_ttm` re-listed 3,358
-- securities. The TTMs were already wrong, not merely inconsistent: Apple's TTM capex summed SEC's
-- positive quarters with Yahoo's negative ones and read +189,000,000 for the year to 2026-09-26.
-- After `derive_ttm`, -9,041,000,000, the year's own figure.

alter table market.metric_source_field add column if not exists sign smallint not null default 1;
alter table market.metric_source_field drop constraint if exists metric_source_field_sign_check;
alter table market.metric_source_field
  add constraint metric_source_field_sign_check check (sign in (-1, 1));
comment on column market.metric_source_field.sign is
  'How this provider states the metric relative to the metric''s own sign: -1 where it states an '
  'outflow as a positive payment (SEC company facts), 1 otherwise. The derivation multiplies by it.';

alter table market.metric add column if not exists is_outflow boolean not null default false;
comment on column market.metric.is_outflow is
  'Cash leaving the company. Stored negative, as a cash-flow statement presents it.';

-- Asserted for every row, so a re-application resets what it does not name.
update market.metric
   set is_outflow = code in ('capital_expenditure', 'buyback', 'dividends_paid');
update market.metric
   set notes = 'an outflow, stored negative; metric_source_field.sign turns a provider that states '
               'it positive'
 where code in ('capital_expenditure', 'buyback', 'dividends_paid');

update market.metric_source_field
   set sign = case when source_code in ('sec-xbrl', 'sec-xbrl-ytd')
                    and metric_code in ('capital_expenditure', 'buyback', 'dividends_paid')
                   then -1 else 1 end;

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
      -- IN THE METRIC'S OWN SIGN: an outflow is negative (migration 20261108235000), and a
      -- provider that states it as a positive payment carries `sign = -1`.
      f.sign * (src.data ->> f.field)::numeric,
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
  --    It is the year's fourth quarter, so it takes the year's fiscal label.
  --    A SERIES OF ONE SIGN THAT LEAVES A REMAINDER OF THE OTHER is a year and quarters that
  --    disagree (a restatement, a change of scope): no number rather than a wrong one. Judged in
  --    each metric's natural orientation, so capex, stored negative, is guarded as it was when
  --    it was stored positive, and a loss-making company's profitable Q4 is still derived.
  create temporary table _q4 on commit drop as
  select a.security_id, a.metric_code, a.as_of, a.value - q.s3 as value, a.currency_code,
         case when a.fiscal_period = 'FY' then a.fiscal_year end as fiscal_year,
         case when a.fiscal_period = 'FY' then 'Q4' end as fiscal_period
    from market.security_metric a
    join market.metric mt on mt.code = a.metric_code and mt.is_flow
    join _ttm_page pg on pg.security_id = a.security_id
   cross join lateral (select case when mt.is_outflow then -1 else 1 end as o) o
   cross join lateral (
     select count(*) as n, sum(m.value) as s3, min(m.as_of) as first_q, max(m.as_of) as last_q,
            -- IN THE METRIC'S NATURAL ORIENTATION: an outflow is stored negative, so its series
            -- is judged as the payments it records (`o` is -1 for an outflow, 1 otherwise).
            bool_and(m.value * o.o >= 0) as nonneg,
            -- Two unknown currencies are not a match: a null on either side fails this.
            bool_and(m.currency_code = a.currency_code) as same_ccy
       from market.security_metric m
      where m.security_id = a.security_id
        and m.metric_code = a.metric_code
        and m.period_type = 'quarter'
        -- THE YEAR'S OWN SOURCE, OR A SOURCE COMPUTED FROM IT (`data_source.computed_from`): a SEC
        -- filer's Q2 and Q3 cash flow are `sec-xbrl-ytd`, computed from `sec-xbrl`'s own facts.
        and (m.source_code = a.source_code
             or exists (select 1 from market.data_source d
                         where d.code = m.source_code and d.computed_from = a.source_code))
        and m.as_of > a.as_of - 300
        and m.as_of < a.as_of) q
   where a.period_type = 'annual'
     and q.n = 3
     and a.as_of - q.last_q between 80 and 120
     and q.last_q - q.first_q between 165 and 200
     and q.same_ccy
     and not (q.nonneg and a.value * o.o >= 0 and (a.value - q.s3) * o.o < 0)
     and not exists (
       select 1 from market.security_metric x
        where x.security_id = a.security_id and x.metric_code = a.metric_code
          and x.period_type = 'quarter' and x.source_code <> 'derived-q4'
          and x.as_of between a.as_of - 10 and a.as_of + 10);

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at,
     fiscal_year, fiscal_period)
  select security_id, metric_code, 'quarter', as_of, value, currency_code, 'derived-q4', now(),
         fiscal_year, fiscal_period
    from _q4
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value,
        currency_code = excluded.currency_code,
        fetched_at = excluded.fetched_at,
        fiscal_year = excluded.fiscal_year,
        fiscal_period = excluded.fiscal_period
    where market.security_metric.source_code = 'derived-q4'
      and (market.security_metric.value, market.security_metric.currency_code,
           market.security_metric.fiscal_year, market.security_metric.fiscal_period)
          is distinct from
          (excluded.value, excluded.currency_code, excluded.fiscal_year, excluded.fiscal_period);

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
  --    A TTM TAKES THE LABEL OF ITS LAST QUARTER, the period it ends with.
  create temporary table _ttm on commit drop as
  select q.security_id, q.metric_code, q.as_of, q.ttm_value, q.currency_code,
         q.fiscal_year, q.fiscal_period
    from (
      select m.security_id, m.metric_code, m.as_of, m.currency_code, m.fiscal_year, m.fiscal_period,
             sum(m.value)         over w as ttm_value,
             count(*)             over w as quarters,
             min(m.as_of)         over w as window_start,
             min(m.currency_code) over w as min_ccy,
             max(m.currency_code) over w as max_ccy,
             min(m.gap)           over g as min_gap
        from (
          select m.security_id, m.metric_code, m.as_of, m.value, m.currency_code,
                 m.fiscal_year, m.fiscal_period,
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
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at,
     fiscal_year, fiscal_period)
  select security_id, metric_code, 'ttm', as_of, ttm_value, currency_code, 'derived', now(),
         fiscal_year, fiscal_period
    from _ttm
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value,
        currency_code = excluded.currency_code,
        fetched_at = excluded.fetched_at,
        fiscal_year = excluded.fiscal_year,
        fiscal_period = excluded.fiscal_period
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code)
      and (market.security_metric.value, market.security_metric.currency_code,
           market.security_metric.fiscal_year, market.security_metric.fiscal_period)
          is distinct from
          (excluded.value, excluded.currency_code, excluded.fiscal_year, excluded.fiscal_period);

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

-- THE REPAIR (header). Once, by version.
update market.security_metric m
   set value = -m.value,
       fetched_at = now()
  from market.metric_source_field f
 where f.sign = -1
   and f.source_code = m.source_code
   and f.metric_code = m.metric_code
   and m.value <> 0;
