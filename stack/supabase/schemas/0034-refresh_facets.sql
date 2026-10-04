CREATE OR REPLACE FUNCTION market.refresh_facets()
 RETURNS TABLE(rows_refreshed bigint, refreshed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog'
AS $function$
begin
  -- THE SYMBOL MAP IS NOT REFRESHED HERE SINCE 2026-10-04. Its inputs are written by Dagster and by
  -- the Track button, which refresh it through `refresh_symbol_map`; this keeps the screener's spine.
  refresh materialized view concurrently market.security_facets;
  return query
    select count(*)::bigint, max(f.refreshed_at) from market.security_facets f;
end;
$function$;
