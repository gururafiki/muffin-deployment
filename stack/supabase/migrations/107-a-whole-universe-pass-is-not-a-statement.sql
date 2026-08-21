-- `derive_ttm(null)` RECOMPUTED THE WHOLE UNIVERSE IN ONE STATEMENT, AND THE UNIVERSE GREW.
--
-- Migration 104 shipped it that way and it worked: 83,247 rows in one call, ~14 seconds. Then the
-- XBRL quarterly rebuild finished and `security_metric` went from **55,390 quarterly rows to
-- 1,390,700** — a 25x input on the same statement. Measured 2026-08-21, every invocation now
-- returns `canceling statement due to statement timeout`, and because `security-metrics` calls it
-- last, the whole resource reports `ok: false` and the metric layer stops advancing.
--
-- The failure is honest and total, which is the only good thing about it: nothing was written
-- wrong, the resource simply stopped. But it is the same shape this file has recorded before —
-- unlimited work in one statement worked on a smaller table and was never bounded.
--
-- ── A PAGE'S SOURCE SET IS AN ANTI-JOIN, NOT AN ORDERING ────────────────────────────────────────
--
-- The obvious fix — `limit N` over the same select — is the defect migration 92 was written to
-- correct: the same N rows every call, "progress" for ever. So the page here is a set of SECURITIES
-- whose TTM is genuinely out of date, defined as: no TTM at all, or a quarterly metric fetched more
-- recently than the newest TTM derived from it. A security that is up to date leaves the set, which
-- is what makes repeated calls terminate.
--
-- The predicate lives in `pending_ttm` and the function uses THAT VIEW rather than restating it,
-- so the backlog and the work cannot disagree about what "done" means.

drop view if exists market.pending_ttm;
create view market.pending_ttm as
select q.security_id
from (
  select m.security_id, max(m.fetched_at) as newest_quarter
  from market.security_metric m
  join market.metric mt on mt.code = m.metric_code and mt.is_flow
  where m.period_type = 'quarter'
  group by m.security_id
) q
left join (
  select t.security_id, max(t.fetched_at) as newest_ttm
  from market.security_metric t
  where t.period_type = 'ttm'
  group by t.security_id
) d on d.security_id = q.security_id
where d.newest_ttm is null or d.newest_ttm < q.newest_quarter;

comment on view market.pending_ttm is
  'Securities whose TTM is missing or older than the quarterly metrics it is derived from. Shared with market.derive_ttm so the backlog and the work cannot disagree about what "done" means.';

grant select on market.pending_ttm to service_role;

-- Drop-then-create: `create or replace function` PRESERVES the existing ACL, so a re-run migration
-- can only ever ADD a privilege — a line tightening permissions applies cleanly and changes nothing.
drop function if exists market.derive_ttm(uuid);
drop function if exists market.derive_ttm(uuid, integer);

create function market.derive_ttm(p_security_id uuid default null, p_limit integer default 400)
returns integer
language plpgsql
as $$
declare v_written integer := 0;
begin
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
      and (
        p_security_id is not null
          -- BOUNDED BY THE BACKLOG, not by a bare `limit` over the rows. A `limit` on the outer
          -- select would take the same first N rows on every call; this takes N SECURITIES that
          -- are actually out of date, and they leave the set once derived.
          or m.security_id in (select security_id from market.pending_ttm limit p_limit)
      )
      and (p_security_id is null or m.security_id = p_security_id)
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
  return v_written;
end;
$$;

comment on function market.derive_ttm(uuid, integer) is
  'Rolling four-quarter sums for flow metrics. Paged over market.pending_ttm because the whole-universe form timed out once the quarterly series reached 1.39M rows — a page here is a set of SECURITIES that are out of date, never a `limit` over rows, which would return the same page for ever.';

revoke execute on function market.derive_ttm(uuid, integer) from public;
grant execute on function market.derive_ttm(uuid, integer) to service_role;

-- Serves both the backlog and the window function's partition.
create index if not exists security_metric_quarter_idx
  on market.security_metric (security_id, metric_code, as_of)
  where period_type = 'quarter';

notify pgrst, 'reload schema';
