-- A TTM IS FOUR CONSECUTIVE QUARTERS, SEC'S MISSING FOURTH QUARTER IS DERIVED, AND THE WORKER MAY
-- RUN IT.
--
-- THE DEFECT. `derive_ttm` summed any four quarters within 370 days, and SEC's XBRL resource writes
-- Q1-Q3 only: the 10-K carries the fourth. So the window ending at a first quarter was
-- Q1 + Q2 + Q3 + the NEXT Q1, spanning ~364 days: a year with its fourth quarter missing and its
-- first counted twice. Measured 2026-10-10 on revenue: **81,515 TTM rows in 3,439 securities** came
-- from windows spanning 341-370 days, against 2,819 from consecutive quarters. Apple's TTM revenue
-- at 2025-12-27 was 457.45bn (124.30 + 95.36 + 94.04 + 143.76) where the true figure is 435.62bn,
-- because Q1 is the holiday quarter. Every TTM ratio inherited it: P/E, P/S, P/FCF.
--
-- THE FIX, decided 2026-10-10 (umbrella docs/specs/2026-10-10-yahoo-company-data.md, As built):
--   * The fiscal Q4 is DERIVED as the year less its first three quarters, for flows only, when the
--     annual and exactly three consecutive discrete quarters of the same source and currency lie
--     inside the year. 28,220 SEC fiscal years qualify (2,674 securities). Written with its own
--     source, `derived-q4`, so a computed quarter says so and is never mistaken for a filing; it
--     never replaces a provider's quarter, and none is derived where a provider's Q4 sits within
--     ten days of the year end (Yahoo dates a quarter by month end, SEC by the period's last day).
--   * Skipped when a non-negative series leaves a negative remainder: 806 fiscal years, whose inputs
--     disagree (a restatement, or a scope change between the 10-Qs and the 10-K). No number rather
--     than a wrong one.
--   * A TTM needs four CONSECUTIVE quarters: the window spans 240-300 days. Above that a quarter is
--     missing; below it the same quarter is in the window twice (two sources, dates days apart).
--   * TTMs and derived Q4s a run no longer produces are RETRACTED for the securities it evaluated.
--     An upsert cannot retract, and without this the 81,515 rows would outlive the rule that stopped
--     producing them.
--
-- THE MARKER. `pending_ttm` asked whether the newest TTM was older than the newest quarter, so a
-- security whose quarters can never form a TTM stayed pending for ever: 656 of 4,094 on 2026-10-10.
-- `derive_ttm` now records that it LOOKED (`market.ttm_derivation`), and the backlog asks whether a
-- quarter or a year arrived after that. A year counts because it is what makes a fourth quarter
-- derivable. The table starts EMPTY on purpose: every security with flows (12,038) is evaluated
-- once more under the new rule, which is the pass that retracts the wrong rows.
--
-- THE GRANTS. Phase 4 moves the derivation to Dagster, where it runs as `ingest_rw` with a 120 s
-- timeout instead of PostgREST's 8 s (`muffin-metrics` failed 101 of 334 runs in the week to
-- 2026-10-10). `ingest_rw` held EXECUTE on neither function nor on `source_priority`, which both
-- call inside their upserts. It already holds DML on the tables and TEMP on the database.
--
-- ORDER WITHIN ONE TRANSACTION. `now()` is transaction time: derive metrics BEFORE the TTM, or a
-- quarter written after the marker carries the same timestamp and reads as already evaluated.

grant execute on function
  market.derive_security_metrics(integer),
  market.derive_ttm(uuid, integer),
  market.source_priority(text)
to ingest_rw;

insert into market.data_source (code, name, priority)
values ('derived-q4', 'Fiscal fourth quarter: the year less its first three quarters', 40)
on conflict (code) do nothing;

create table if not exists market.ttm_derivation (
  security_id uuid primary key references market.security (security_id) on delete cascade,
  derived_at  timestamptz not null
);
comment on table market.ttm_derivation is
  'When derive_ttm last evaluated a security, whether or not it could form a TTM. pending_ttm asks '
  'whether a quarter or a year arrived after it, so a security whose quarters can never form a TTM '
  'leaves the backlog after one look rather than staying for ever.';

grant select, insert, update, delete on market.ttm_derivation to service_role, ingest_rw;
alter table market.ttm_derivation enable row level security;
drop policy if exists ttm_derivation_public_read on market.ttm_derivation;
create policy ttm_derivation_public_read on market.ttm_derivation for select using (true);

create or replace view market.pending_ttm as
select q.security_id
  from (select m.security_id, max(m.fetched_at) as newest_input
          from market.security_metric m
          join market.metric mt on mt.code = m.metric_code and mt.is_flow
         where m.period_type = any (array['quarter'::text, 'annual'::text])
           and m.source_code <> all (array['derived'::text, 'derived-q4'::text])
         group by m.security_id) q
  left join market.ttm_derivation d on d.security_id = q.security_id
 where d.derived_at is null or d.derived_at < q.newest_input;

create or replace function market.derive_ttm(p_security_id uuid default null::uuid,
                                             p_limit integer default 400)
 returns integer
 language plpgsql
as $function$
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
  --    currency, consecutive (Q1 to Q3 170-200 days, Q3 to the year end 80-100).
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
     and a.as_of - q.last_q between 80 and 100
     and q.last_q - q.first_q between 170 and 200
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
  create temporary table _ttm on commit drop as
  select q.security_id, q.metric_code, q.as_of, q.ttm_value, q.currency_code
    from (
      select m.security_id, m.metric_code, m.as_of, m.currency_code,
             sum(m.value)         over w as ttm_value,
             count(*)             over w as quarters,
             min(m.as_of)         over w as window_start,
             min(m.currency_code) over w as min_ccy,
             max(m.currency_code) over w as max_ccy
        from market.security_metric m
        join market.metric mt on mt.code = m.metric_code and mt.is_flow
        join _ttm_page pg on pg.security_id = m.security_id
       where m.period_type = 'quarter'
      window w as (partition by m.security_id, m.metric_code
                   order by m.as_of rows between 3 preceding and current row)
    ) q
   where q.quarters = 4
     and q.as_of - q.window_start between 240 and 300
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
