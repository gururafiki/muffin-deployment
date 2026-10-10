-- THE DAGSTER WORKER MAY DERIVE METRICS AND TTM, AND A TTM BACKLOG CAN DRAIN.
--
-- WHY THE GRANTS. Phase 4 moves the metric derivation off the edge (umbrella
-- docs/specs/2026-10-10-yahoo-company-data.md, decision 1). The edge calls it through PostgREST,
-- whose role stops a statement at 8 s, and `muffin-metrics` failed 101 of 334 runs in the week to
-- 2026-10-10, 90% of them between 00:00 and 01:00 UTC while the price night loads the database.
-- From Dagster the same calls run as `ingest_rw`, whose timeout is 120 s. Measured on production
-- 2026-10-10, `ingest_rw` held EXECUTE on neither function, AND NOT ON `source_priority`, which both
-- call inside their upserts: granting the two alone would have failed on the first conflict with
-- `permission denied for function source_priority`. All three are SECURITY INVOKER, so the worker
-- also needs DML on `security_metric` and `security_statement`, which it already holds, and TEMP on
-- the database for `derive_security_metrics`' page table, which it also holds. Additive: the edge
-- keeps working until its retirement.
--
-- WHY THE MARKER. `pending_ttm` asked "is the newest TTM older than the newest quarter", and a
-- security whose quarters can never form a TTM (fewer than four, or four that span more than 370
-- days) never gets one, so it stays pending for ever. Measured 2026-10-10: of 4,094 pending, 3,376
-- could form one at their newest quarter, 62 only at an older one, and 656 NEVER. A backlog with a
-- floor that cannot drain makes its own depth meaningless, and fires the flat-backlog alert as soon
-- as the derivable ones are done. `derive_ttm` now records that it LOOKED at a security, whatever it
-- found, and the backlog asks whether a quarter arrived after that. A security leaves after one
-- evaluation and returns only with a new quarter: the `security_statement.derived_at` pattern, at
-- the grain the TTM is computed at.
--
-- SEEDED SO THE BACKLOG IS UNCHANGED AT CUTOVER. A security's last evaluation is taken to be its
-- newest TTM row, so the new view returns exactly the securities the old one did; only the 656
-- leave it, and only after the next evaluation.
--
-- ORDER WITHIN ONE TRANSACTION. `now()` is transaction time. Derive metrics BEFORE the TTM: a quarter
-- written after `derive_ttm` in the same transaction carries the same timestamp as the marker and
-- would read as already evaluated. The Dagster asset commits each call separately.

grant execute on function
  market.derive_security_metrics(integer),
  market.derive_ttm(uuid, integer),
  market.source_priority(text)
to ingest_rw;

create table if not exists market.ttm_derivation (
  security_id uuid primary key references market.security (security_id) on delete cascade,
  derived_at  timestamptz not null
);
comment on table market.ttm_derivation is
  'When derive_ttm last evaluated a security, whether or not a TTM could be formed. pending_ttm asks '
  'whether a quarter arrived after it, so a security whose quarters can never form a TTM leaves the '
  'backlog after one look rather than staying for ever.';

grant select, insert, update, delete on market.ttm_derivation to service_role, ingest_rw;
alter table market.ttm_derivation enable row level security;
drop policy if exists ttm_derivation_public_read on market.ttm_derivation;
create policy ttm_derivation_public_read on market.ttm_derivation for select using (true);

insert into market.ttm_derivation (security_id, derived_at)
select security_id, max(fetched_at)
  from market.security_metric
 where period_type = 'ttm'
 group by security_id
on conflict (security_id) do nothing;

create or replace function market.derive_ttm(p_security_id uuid default null::uuid,
                                             p_limit integer default 400)
 returns integer
 language plpgsql
as $function$
declare v_written integer := 0;
begin
  -- THE PAGE, CHOSEN ONCE, so the marker below records exactly the securities evaluated. One named
  -- security, or up to `p_limit` from the backlog. The backlog is an anti-join over the marker, so
  -- successive pages advance whether or not a page produced a TTM.
  create temporary table _ttm_page on commit drop as
  select p.security_id from market.pending_ttm p
   where p_security_id is null
   limit p_limit;
  if p_security_id is not null then
    insert into _ttm_page (security_id) values (p_security_id);
  end if;

  insert into market.security_metric
    (security_id, metric_code, period_type, as_of, value, currency_code, source_code, fetched_at)
  select
    q.security_id, q.metric_code, 'ttm', q.as_of, q.ttm_value, q.currency_code, 'derived', now()
  from (
    select
      m.security_id,
      m.metric_code,
      m.as_of,
      m.currency_code,
      sum(m.value)   over w as ttm_value,
      count(*)       over w as quarters,
      min(m.as_of)   over w as window_start
    from market.security_metric m
    join market.metric mt on mt.code = m.metric_code and mt.is_flow
    where m.period_type = 'quarter'
      and m.security_id in (select security_id from _ttm_page)
    window w as (
      partition by m.security_id, m.metric_code
      order by m.as_of
      rows between 3 preceding and current row
    )
  ) q
  -- EXACTLY FOUR QUARTERS, INSIDE 370 DAYS. Four rows spanning two years sum to a number that
  -- looks like a TTM and is not; a missing quarter must read as no TTM, not as a smaller year.
  where q.quarters = 4
    and q.as_of - q.window_start <= 370
  on conflict (security_id, metric_code, period_type, as_of) do update
    set value = excluded.value,
        currency_code = excluded.currency_code,
        fetched_at = excluded.fetched_at
    where market.source_priority(excluded.source_code)
       >= market.source_priority(market.security_metric.source_code);

  get diagnostics v_written = row_count;

  -- EVALUATED, WHATEVER IT FOUND. A security whose quarters cannot form a TTM leaves the backlog here
  -- and returns only when a newer quarter arrives.
  insert into market.ttm_derivation (security_id, derived_at)
  select security_id, now() from _ttm_page
  on conflict (security_id) do update set derived_at = excluded.derived_at;

  drop table _ttm_page;
  return v_written;
end;
$function$;

create or replace view market.pending_ttm as
select q.security_id
  from (select m.security_id, max(m.fetched_at) as newest_quarter
          from market.security_metric m
          join market.metric mt on mt.code = m.metric_code and mt.is_flow
         where m.period_type = 'quarter'::text
         group by m.security_id) q
  left join market.ttm_derivation d on d.security_id = q.security_id
 where d.derived_at is null or d.derived_at < q.newest_quarter;
