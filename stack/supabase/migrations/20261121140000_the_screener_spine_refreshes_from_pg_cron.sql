-- THE SCREENER SPINE REFRESHES FROM PG_CRON, OFF THE 8-SECOND RPC CEILING.
--
-- WHY. `security_facets`, the denormalised filter spine every screener aggregate reads, is
-- refreshed hourly by the edge resource `facets-refresh`, which calls `market.refresh_facets()` as
-- one PostgREST RPC under the role's 8 s statement timeout. Measured 2026-11-21 from `refresh_run`:
-- successful runs average 5.1 s on 10-31, 6.5 s in early November and 6.8-7.2 s since 11-16, with a
-- daily maximum of 7.4-8.1 s, and the refresh has failed with `canceling statement due to statement
-- timeout` on 1-10 runs a day since 11-01 (10 on 11-16, 4 on 11-20, 4 by noon on 11-21, at 02:14,
-- 03:14, 04:14 and 11:14, while the price night, the company day and the SEC wave were writing).
-- A failed refresh leaves the screener on the previous hour's spine, and nothing alerts on it:
-- `facets-refresh` is watched by the stalled-resource alert only once it has failed for 12 hours.
--
-- It is the segment spine's history again (20261003190000): a whole-table refresh on an RPC is a
-- timeout waiting for the data to grow (CLAUDE.md, 2026-10-03, which named this one as the next).
--
-- WHAT.
--   1. `refresh_facets()` records `facets.duration_ms` and `facets.rows` in `universe_sample`, as
--      `refresh_segment_spine()` does, and refuses a refresh that would serve an empty spine (the
--      edge handler's guard, moved into the function so it holds whoever calls it). Raising rolls
--      the refresh back, so the previous spine keeps serving.
--   2. `muffin-facets` (:14 hourly) runs it directly as `postgres` with a 300 s bound, the bound the
--      other pg_cron refreshes carry. `market.cron_job_headroom()` (20261121130000) sees it.
--   3. The edge resource retires: it answers 410, and its rotation row stays disabled.
--
-- `create or replace` with an unchanged signature keeps the function's ACL.

create or replace function market.refresh_facets()
returns table (rows_refreshed bigint, refreshed_at timestamp with time zone)
language plpgsql
security definer
set search_path to 'market', 'pg_catalog'
as $function$
declare
  t0 timestamptz := clock_timestamp();
  t1 timestamptz;
  n  bigint;
  at timestamptz;
begin
  -- THE SYMBOL MAP IS NOT REFRESHED HERE SINCE 2026-10-04. Its inputs are written by Dagster and by
  -- the Track button, which refresh it through `refresh_symbol_map`; this keeps the screener's spine.
  -- CONCURRENTLY, so readers are never blocked; it needs the spine's unique index.
  refresh materialized view concurrently market.security_facets;
  select count(*), max(f.refreshed_at) into n, at from market.security_facets f;
  -- A spine with no rows is the Markets tab showing an empty universe, not a refresh. Raising
  -- rolls the refresh back, so the previous spine keeps serving.
  if n = 0 then
    raise exception 'refresh_facets: the spine would serve an empty universe; refresh rolled back';
  end if;
  t1 := clock_timestamp();
  -- ONE timestamp for both rows: `universe_sample` is keyed (sampled_at, metric).
  insert into market.universe_sample (sampled_at, metric, value)
  values (t1, 'facets.duration_ms', (extract(epoch from t1 - t0) * 1000)::integer), (t1, 'facets.rows', n)
  on conflict do nothing;
  return query select n, at;
end;
$function$;

-- RETIRES: facets-refresh
update market.cron_resource set enabled = false where resource = 'facets-refresh';

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice '  --  no pg_cron here (the migration tests): nothing to schedule';
    return;
  end if;
  execute $q$
    select cron.schedule(
      'muffin-facets',
      '14 * * * *',
      $c$set statement_timeout = '300s'; select market.refresh_facets()$c$)
  $q$;
end $$;
