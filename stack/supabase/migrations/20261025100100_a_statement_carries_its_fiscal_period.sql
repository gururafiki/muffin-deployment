-- A STATEMENT CARRIES ITS FISCAL PERIOD, AND ITS METRICS INHERIT IT. Phase 5 step 2a of the
-- umbrella's docs/specs/2026-10-24-sec-family.md (decision 7).
--
-- 1. LABELS. `security_statement` and `security_metric` gain `fiscal_year` and `fiscal_period`
--    (FY, H1, H2, Q1-Q4). They are null until a calendar exists (previous migration) and
--    `label_fiscal_periods` has run for the security.
--
--    THE CHECKS ARE NOT VALID ON PURPOSE. Every existing row is null, which the check admits, so
--    validating proves nothing and costs a scan of the table (security_metric is 2.8 GB) while this
--    transaction holds the ACCESS EXCLUSIVE lock `add column` takes: every anon read of the metric
--    and ratio series would wait for it. A NOT VALID check is still enforced on every insert and
--    update, which is the only place a label can come from.
--
-- 2. `label_fiscal_periods(uuid[])`, the one labeller, called by both lanes' stage 2. A statement
--    row takes the nearest CANONICAL period of its class (annual -> FY, quarter -> Q1-Q4, half ->
--    H1/H2) whose end lies within 10 days of the row's, the same 10 days `derive_ttm` uses for "one
--    quarter under two dates". No match writes null, so a corrected calendar retracts a label. Only
--    rows whose label changes are written.
--
-- 3. A NEW LABEL RE-DERIVES THE ROW. The requeue trigger already fires on a change of `as_of`,
--    `data` or `currency`; a change of label now nulls `derived_at` too, so the metrics pick it up
--    through the ordinary derivation rather than through a second writer.
--
-- 4. THE DERIVATIONS CARRY THE LABELS.
--    - `derive_security_metrics` copies them into every metric it writes, including free cash flow
--      and total debt (which take the label of their operating-cash-flow and long-term-debt rows).
--    - Its `derived_at` marking now joins on `source_code` as well: from step 2b two providers can
--      hold one period, and without it marking one would mark the other done underived. It is a
--      no-op until then, because the key does not yet admit two.
--    - Every `do update` now carries an `is distinct from`, so an unchanged metric is not rewritten
--      (the 2026-10-06 lesson: 11.6 M price bars rewritten a night for ~170 k changes). The free cash
--      flow and total debt updates also set `currency_code`, which they used to leave stale.
--    - `derive_ttm`: a `derived-q4` row takes its year's `fiscal_year` and Q4; a TTM row takes the
--      label of its last quarter.
--
-- 5. ONE STATEMENT PER METRIC KEY IN A PAGE. Two statements of one page that map to the same metric
--    (security, metric, period type, date) made the upsert fail outright: `ON CONFLICT DO UPDATE
--    command cannot affect row a second time`, which fails the page and every page after it, the
--    shape of the TRL stall. Found 2026-10-25 by re-deriving AAPL, MSFT and 7203.T in a rolled-back
--    transaction on production with the CURRENT function: the 2,259 `FY` rows (`sec`) and their
--    yfinance `annual` twins map to the same `annual` metric, 4,694 keys across 57 securities. It
--    is latent only because the twins are never underived together, and the label pass (step 8)
--    re-queues every statement of a security at once, as step 2b's two-provider key will. The page
--    now keeps one statement per metric key: the highest source priority, then the newest `as_of`.
--    The other is still marked derived, because it was considered.
--
-- Nothing here changes a served number. Before any calendar exists every label is null, and the
-- derivations produce the same values as before.
--
-- Guards: stack/supabase/tests/a-statement-takes-the-label-of-its-own-fiscal-period.sql and
-- stack/supabase/tests/two-statements-for-one-metric-are-one-metric.sql.

alter table market.security_statement
  add column if not exists fiscal_year smallint,
  add column if not exists fiscal_period text;
alter table market.security_metric
  add column if not exists fiscal_year smallint,
  add column if not exists fiscal_period text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'security_statement_fiscal_period_check') then
    alter table market.security_statement
      add constraint security_statement_fiscal_period_check
      check (fiscal_period in ('FY', 'H1', 'H2', 'Q1', 'Q2', 'Q3', 'Q4')) not valid;
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'security_metric_fiscal_period_check') then
    alter table market.security_metric
      add constraint security_metric_fiscal_period_check
      check (fiscal_period in ('FY', 'H1', 'H2', 'Q1', 'Q2', 'Q3', 'Q4')) not valid;
  end if;
end $$;

comment on column market.security_statement.fiscal_year is
  'The fiscal year this period belongs to, from the company''s canonical fiscal calendar '
  '(market.fiscal_period). Null until labelled, or when no canonical period lies within 10 days.';
comment on column market.security_statement.fiscal_period is
  'FY, H1, H2 or Q1-Q4, with fiscal_year. Set only by market.label_fiscal_periods.';

-- 2. The labeller.
create or replace function market.label_fiscal_periods(p_security_ids uuid[])
 returns integer
 language plpgsql
as $function$
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

revoke execute on function market.label_fiscal_periods(uuid[]) from public;
grant execute on function market.label_fiscal_periods(uuid[]) to service_role, ingest_rw;

-- 3. The requeue trigger.
CREATE OR REPLACE FUNCTION market.security_statement_requeue()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- A CORRECTED CURRENCY RE-DERIVES TOO: the metrics carry the statement's currency, so a row
  -- relabelled after it was derived would otherwise keep serving the old (or withheld) label.
  -- So does a new FISCAL LABEL, which the metrics carry the same way.
  if new.as_of is distinct from old.as_of or new.data is distinct from old.data
     or new.currency is distinct from old.currency
     or new.fiscal_year is distinct from old.fiscal_year
     or new.fiscal_period is distinct from old.fiscal_period then
    new.derived_at := null;
  end if;
  return new;
end;
$function$;

-- 4a. The metrics.
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

-- 4b. The fourth quarter and the TTM.
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
  create temporary table _q4 on commit drop as
  select a.security_id, a.metric_code, a.as_of, a.value - q.s3 as value, a.currency_code,
         case when a.fiscal_period = 'FY' then a.fiscal_year end as fiscal_year,
         case when a.fiscal_period = 'FY' then 'Q4' end as fiscal_period
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
