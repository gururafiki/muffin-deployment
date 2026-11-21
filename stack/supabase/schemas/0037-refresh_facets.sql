CREATE OR REPLACE FUNCTION market.refresh_facets()
 RETURNS TABLE(rows_refreshed bigint, refreshed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog'
AS $function$
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
