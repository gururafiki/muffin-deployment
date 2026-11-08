-- A RETRACTED STATEMENT TAKES ITS METRICS WITH IT, AND THE NEXT SOURCE FILLS THE GAP.
--
-- WHY. `derive_security_metrics` only adds or overwrites: it reads the statements still to derive and
-- upserts one metric per key. When the SEC filer lane re-parses a filer and a statement is no longer
-- produced, `retract_unproduced` deletes the statement, and nothing touches the metric derived from
-- it. That metric keeps its old value and its old fiscal label. The source-priority guard then stops
-- a lower-priority provider's statement at the same key from replacing it, even once re-derived.
--
-- Found 2026-11-08, after muffin-ingest#164 rebuilt 49 SEC calendars and the whole grid was re-parsed
-- on them (backfill `pyufqdue`: 85 statements retracted). Both calendars it was written for came out
-- right, and `check_one_period_one_point` still failed on exactly those two:
--   * Magnera: the `sec-xbrl` statement for 2022-12-31 (Glatfelter's December year, now
--     non-canonical under Berry's September calendar) was retracted, and its revenue metric still
--     read 1,491,326,000, labelled FY 2022, 273 days from FY 2023.
--   * Republic Airways: likewise for Mesa's 2024-09-30 year, labelled FY 2024, 274 days from FY 2023.
-- Across the table, 1,286 labelled metrics had no statement at their own source, period and period
-- type: 105 annual, 16 half-year and 1,066 quarterly `sec-xbrl` rows and 99 computed quarters, in
-- about 80 securities. The edge never wrote fiscal labels, so a labelled metric was derived from a
-- statement; these all outlived theirs. (The ~48,900 UNLABELLED `sec-xbrl` metrics with no statement
-- were written by the retired `security-xbrl` edge resource; Phase 5 step 11's contract lists them.)
--
-- WHAT.
--   1. `security_statement_retract`, AFTER DELETE, once per statement with the deleted rows as a
--      transition table. For each deleted statement:
--        - delete the metrics it could have produced (`metric_source_field` for its source and
--          statement) at its own source, period and period type. A metric another source won is
--          untouched: deleting yfinance's statement must not delete SEC's revenue;
--        - where that removed an input, delete the `derived` free cash flow (operating cash flow,
--          capital expenditure) or total debt (long- and short-term debt) at the same key;
--        - re-queue every remaining statement at those keys (`derived_at = null`), so the next source
--          by priority fills them, unlabelled where its period is off the calendar (decision 11);
--        - re-queue the security's TTM (`ttm_derivation`): `pending_ttm` waits for a newer input,
--          and a deletion is not one.
--      Only the SEC filer lane deletes statements (Yahoo's statement writer merges and never
--      retracts), so this acts where a re-parse no longer produces a period, and on step 11's
--      deletes of the retired `sec` rows, whose metrics should then be re-derived the same way.
--   2. The one-off repair of the 1,286, by the same steps. The orphans' statements are already gone,
--      so the trigger cannot see them; they are found as labelled metrics at a statement source with
--      no statement at their own key.
--
-- An invariant every writer must remember is a trigger (CLAUDE.md, `derived_at`), and this is the
-- same table's other half: a BEFORE UPDATE trigger already re-queues a changed statement.
--
-- Guard: stack/supabase/tests/a-retracted-statement-takes-its-metrics-with-it.sql.

create or replace function market.security_statement_retract()
 returns trigger
 language plpgsql
as $function$
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

drop trigger if exists security_statement_retract on market.security_statement;
create trigger security_statement_retract
  after delete on market.security_statement
  referencing old table as retracted
  for each statement execute function market.security_statement_retract();

-- THE REPAIR: the labelled metrics already orphaned, by the same steps.
with orphans as (
  delete from market.security_metric m
   where m.fiscal_year is not null
     and m.source_code in (select distinct source_code from market.metric_source_field)
     and m.period_type in ('annual', 'quarter', 'half')
     and not exists (
       select 1 from market.security_statement st
        where st.security_id   = m.security_id
          and st.source_code   = m.source_code
          and st.period_ending = m.as_of
          and case when lower(coalesce(st.period_type, 'annual')) in ('fy', 'annual') then 'annual'
                   when lower(st.period_type) like 'q%' then 'quarter'
                   else lower(st.period_type) end = m.period_type)
  returning m.security_id, m.metric_code, m.period_type, m.as_of
),
stale_derived as (
  delete from market.security_metric d
   using orphans r
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
    from (select distinct security_id, period_type, as_of from orphans) k
   where st.security_id   = k.security_id
     and st.period_ending = k.as_of
     and case when lower(coalesce(st.period_type, 'annual')) in ('fy', 'annual') then 'annual'
              when lower(st.period_type) like 'q%' then 'quarter'
              else lower(st.period_type) end = k.period_type
     and st.derived_at is not null
  returning st.security_id
),
ttm as (
  delete from market.ttm_derivation t
   where t.security_id in (select security_id from orphans
                           union select security_id from stale_derived
                           union select security_id from requeued)
  returning t.security_id
)
select (select count(*) from orphans)       as orphan_metrics,
       (select count(*) from stale_derived) as derived_removed,
       (select count(*) from requeued)      as statements_requeued,
       (select count(*) from ttm)           as ttm_requeued;
