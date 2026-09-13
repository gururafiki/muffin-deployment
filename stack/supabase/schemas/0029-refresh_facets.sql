CREATE OR REPLACE FUNCTION market.refresh_facets()
 RETURNS TABLE(rows_refreshed bigint, refreshed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog'
AS $function$
begin
  -- THE SYMBOL MAP FIRST. `security_facets` is what the screener reads and the symbol map is what
  -- every chart reads; refreshing them in one call is what stops the second one being forgotten.
  refresh materialized view concurrently market.symbol_security;
  refresh materialized view concurrently market.security_facets;
  return query
    select count(*)::bigint, max(f.refreshed_at) from market.security_facets f;
end;
$function$;
