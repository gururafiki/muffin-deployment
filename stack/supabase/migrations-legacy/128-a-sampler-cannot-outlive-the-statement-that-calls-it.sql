-- A SAMPLER CANNOT OUTLIVE THE STATEMENT THAT CALLS IT.
--
-- Migration 127 shipped `sample_backlogs()` as ONE function that loops over all 26 `pending_*`
-- views, with a per-item `set_config('statement_timeout', '10s', true)` and an overall deadline —
-- because the counts were measured at ~8,400 ms in total and `pending_prices` alone at 5,380 ms.
--
-- The first production call returned, at 8,068 ms:
--
--     {"resource":"observability-sample","ok":false,
--      "error":"sample_backlogs failed: canceling statement due to statement timeout"}
--
-- THE MITIGATION COULD NEVER HAVE WORKED, and the reason is worth writing down. PostgreSQL arms
-- the statement timer ONCE, when the statement begins; assigning `statement_timeout` afterwards
-- does not re-arm it for the statement already running. A PostgREST RPC is a SINGLE statement, so
-- the role's 8-second limit bounds the WHOLE function — including every per-item timeout and the
-- exception handler meant to record a failure. The isolation was inside the thing being killed.
--
-- The loop therefore has to live OUTSIDE the statement. The edge function drives it: one RPC per
-- backlog, each bounded by the slowest single view (5.4s, comfortably under 8s), all sharing one
-- `sampled_at` so they still form a single coherent sample.
--
-- AND THE ERROR ROW HAS TO BE WRITTEN BY THE CALLER. A statement timeout aborts its transaction,
-- so a function that catches its own timeout and inserts a row records nothing — the insert dies
-- with it. `index.ts` writes the `error` row after a failed RPC, which is the only place that
-- survives. NULL depth is not zero, and a backlog that has started timing out must not read as
-- drained.

-- The old signature goes rather than being left beside the new one: `create or replace function`
-- keys on the ARGUMENT LIST, so a superseded signature becomes an OVERLOAD, and two candidates
-- make PostgREST fail the RPC outright with "Could not choose the best candidate function".
drop function if exists market.sample_backlogs(integer, text);

-- Which backlogs exist. Discovered from `pg_class`, never a hardcoded list — `pending_%` is
-- already a load-bearing naming convention (`every-table-is-reachable.sql` classifies work queues
-- by it) and a hand-maintained copy drifts within weeks.
create or replace function market.backlogs_to_sample()
returns setof text
language sql
stable
security definer
set search_path = market, pg_catalog, pg_temp
as $$
  select c.relname
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'market'
     and c.relkind in ('v', 'm')
     and c.relname like 'pending\_%'
   order by c.relname
$$;

-- Count ONE backlog. `p_sampled_at` is passed in rather than defaulted to `now()` so that all 26
-- rows of a sweep share an instant and can be read as one reading; `now()` per call would smear a
-- sample across the ~9 seconds it takes and make "depth at time T" un-plottable.
create or replace function market.sample_backlog(
  p_backlog    text,
  p_sampled_at timestamptz
) returns bigint
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  n  bigint;
  t0 timestamptz := clock_timestamp();
begin
  -- Only a discovered backlog, so this cannot be turned into "count any relation you name" by a
  -- caller. It is SECURITY DEFINER and reachable over the API by service_role.
  if not exists (select 1 from market.backlogs_to_sample() b where b = p_backlog) then
    raise exception 'not a backlog: %', p_backlog;
  end if;

  execute format('select count(*) from market.%I', p_backlog) into n;

  insert into market.backlog_sample (sampled_at, backlog, depth, duration_ms, error)
       values (p_sampled_at, p_backlog, n,
               extract(epoch from clock_timestamp() - t0) * 1000, null)
  on conflict (sampled_at, backlog) do update
     set depth = excluded.depth, duration_ms = excluded.duration_ms, error = null;

  return n;
end $$;

revoke all on function market.backlogs_to_sample()                    from public;
revoke all on function market.sample_backlog(text, timestamptz)       from public;
grant execute on function market.backlogs_to_sample()                 to service_role;
grant execute on function market.sample_backlog(text, timestamptz)    to service_role;

notify pgrst, 'reload schema';
