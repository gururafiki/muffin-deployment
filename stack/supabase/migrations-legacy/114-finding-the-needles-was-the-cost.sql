-- 97 STATEMENTS OUT OF 107,784 QUALIFY, SO EVERY CALL SCANNED ALL OF THEM.
--
-- `derive_security_metrics` selected the statements with no matching metric via a NOT EXISTS
-- against `security_metric` (3.29M rows) and then applied `limit N`. Because almost everything is
-- already derived, Postgres had to evaluate that anti-join for nearly the WHOLE statement table
-- before it could find even 25 qualifying rows.
--
-- Measured against production, before and after adding an index on `security_statement (as_of)`:
--
--     p_limit    25   ->  8.13s TIMEOUT   |  after: 8.67s
--     p_limit    50   ->  6.86s           |  after: 6.68s
--     p_limit   100   ->  6.17s           |  after: 6.60s
--     p_limit   200   ->  6.12s           |  after: 6.10s
--
-- **The index changed nothing, and that measurement is the point.** Migration 112 reasoned that a
-- LIMIT after a SORT pays for the whole sort — true in general, and not the cost here. Ordering was
-- never the problem; FINDING THE NEEDLES was. I had also tuned the page twice (2,000 -> 200) before
-- measuring. Three attempts, two wrong theories, because the cost is flat in the page size and that
-- fact was visible in the very first table.
--
-- ── A MARKER TURNS A SCAN INTO A LOOKUP ─────────────────────────────────────────────────────────
--
-- `security_statement.derived_at` records that a statement has been turned into metrics, so "needs
-- deriving" becomes `derived_at is null` — an indexed predicate over a handful of rows instead of
-- an anti-join over 3.29M.
--
-- A RE-FETCHED STATEMENT MUST RE-QUEUE, AND THAT IS A TRIGGER, NOT A CONVENTION. The obvious design
-- is "every writer nulls `derived_at` in its upsert" — three call sites today, and the next one
-- forgets. This file has already recorded that a rule written at one call site is not a rule
-- (`fetchWithIsolation`'s outage check lived in a comment at one handler and did not travel). So
-- the invariant lives in a BEFORE UPDATE trigger: change the data or the fetch time and the row
-- re-queues itself, whoever wrote it and whichever resource they add next year.

alter table market.security_statement add column if not exists derived_at timestamptz;

comment on column market.security_statement.derived_at is
  'When this statement was turned into metric rows. NULL means "not yet, or re-fetched since" — the writers null it on every upsert. Exists so the backlog is an indexed lookup rather than a NOT EXISTS over 3.29M metric rows, which cost ~6s against an 8s statement timeout regardless of page size.';

create index if not exists security_statement_underived_idx
  on market.security_statement (as_of)
  where derived_at is null;

-- The invariant, enforced structurally. `is distinct from` rather than `<>` so a NULL on either
-- side still counts as a change — a statement whose `data` goes from null to a payload is exactly
-- the case that must re-derive.
create or replace function market.security_statement_requeue()
returns trigger
language plpgsql
as $$
begin
  if new.as_of is distinct from old.as_of or new.data is distinct from old.data then
    new.derived_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists security_statement_requeue on market.security_statement;
create trigger security_statement_requeue
  before update on market.security_statement
  for each row execute function market.security_statement_requeue();

-- ── BACKFILL, ONCE, BEHIND `one_shot` ───────────────────────────────────────────────────────────
--
-- Everything already derived must be marked, or the first run after this deploy would re-derive
-- 107,784 statements. The 97 that genuinely qualify must be left NULL — marking them would lose
-- their metrics for good, so the backfill runs the SAME anti-join the function used, once, rather
-- than assuming every existing row is done.
--
-- Behind `one_shot` because migrations re-run on every deploy and this is a data repair: re-running
-- it would re-mark statements that a later re-fetch had legitimately re-queued.
do $$
declare v_marked integer;
begin
  if exists (select 1 from market.one_shot where key = '114-derived-at-backfill') then
    return;
  end if;

  update market.security_statement st
     set derived_at = st.as_of
   where st.derived_at is null
     and exists (
       select 1
         from market.security_metric sm
         join market.metric_source_field f2
           on f2.metric_code = sm.metric_code
          and f2.source_code = st.source_code
          and f2.statement   = st.statement
        where sm.security_id = st.security_id
          and sm.as_of       = st.period_ending
          and sm.fetched_at >= st.as_of);
  get diagnostics v_marked = row_count;

  insert into market.one_shot (key, reason)
  values ('114-derived-at-backfill',
          'Marked ' || v_marked || ' already-derived statements so the first run after this deploy '
          || 'does not re-derive the whole table. The ones that genuinely qualify stay NULL.');
end $$;

-- ── AND THE FUNCTION READS THE MARKER ───────────────────────────────────────────────────────────

create or replace function market.derive_security_metrics(p_limit integer default null)
returns integer
language plpgsql
as $$
declare
  v_written integer := 0;
  v_extra   integer := 0;
begin
  -- The page, chosen by an INDEXED predicate. `derived_at is null` is served by
  -- `security_statement_underived_idx`; the NOT EXISTS this replaces had to be evaluated per row.
  create temporary table _src on commit drop as
  select st.security_id, st.statement, st.period_ending, st.currency, st.source_code,
         coalesce(st.period_type, 'annual') as period_type,
         st.data
    from market.security_statement st
   where st.derived_at is null
   order by st.as_of
   limit p_limit;

  create temporary table _touched on commit drop as
  with ins as (
    insert into market.security_metric
      (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
    select
      src.security_id,
      f.metric_code,
      case when lower(src.period_type) in ('fy', 'annual') then 'annual'
           when lower(src.period_type) like 'q%'           then 'quarter'
           else lower(src.period_type) end,
      src.period_ending,
      (src.data ->> f.field)::numeric,
      src.currency,
      src.source_code,
      now()
    from _src src
    join market.metric_source_field f
      on f.source_code = src.source_code
     and f.statement   = src.statement
    where jsonb_typeof(src.data -> f.field) = 'number'
    on conflict (security_id, metric_code, period_type, as_of) do update
      set value = excluded.value,
          currency_code = excluded.currency_code,
          source_code = excluded.source_code,
          fetched_at = excluded.fetched_at
      -- A FILING BEATS A PROVIDER'S SUMMARY. Without this the resource that ran last wins and the
      -- served number depends on cron ordering — 17 years of XBRL quietly replaced by 4 periods of
      -- yfinance, with nothing to show for it but a shorter chart.
      where market.source_priority(excluded.source_code)
         >= market.source_priority(market.security_metric.source_code)
    returning security_id, period_type, as_of
  )
  select security_id, period_type, as_of from ins;

  get diagnostics v_written = row_count;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select ocf.security_id, 'free_cash_flow', ocf.period_type, ocf.as_of,
         ocf.value - abs(capex.value), ocf.currency_code, 'derived', now()
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
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select ltd.security_id, 'total_debt', ltd.period_type, ltd.as_of,
         ltd.value + coalesce(std.value, 0), ltd.currency_code, 'derived', now()
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
    set value = excluded.value, source_code = excluded.source_code, fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);
  get diagnostics v_extra = row_count;
  v_written := v_written + v_extra;

  -- MARK WHAT WAS PROCESSED, keyed at the statement's own grain. Without this the page cannot
  -- advance and every call returns the same rows — the defect migration 92 exists to correct.
  update market.security_statement st
     set derived_at = now()
    from _src s
   where st.security_id    = s.security_id
     and st.statement      = s.statement
     and st.period_ending  = s.period_ending
     and st.period_type    = s.period_type;

  drop table _touched;
  drop table _src;
  return v_written;
end;
$$;

revoke execute on function market.derive_security_metrics(integer) from public;
grant execute on function market.derive_security_metrics(integer) to service_role;

-- The drift counter now reads the marker too, so the view and the work cannot disagree about what
-- "done" means — the rule migration 92 established.
drop view if exists market.pending_metrics;
create view market.pending_metrics as
select st.security_id, st.statement, st.period_ending
from market.security_statement st
where st.derived_at is null;

comment on view market.pending_metrics is
  'Statements not yet turned into metrics. A DRIFT COUNTER, not a work queue: the derivation needs no provider, so this settles to the statements whose provider reports none of the catalogue''s field names. Expected non-zero and stable; the TREND is the signal.';

grant select on market.pending_metrics to service_role;

notify pgrst, 'reload schema';
