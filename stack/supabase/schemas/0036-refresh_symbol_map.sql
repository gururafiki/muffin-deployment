CREATE OR REPLACE FUNCTION market.refresh_symbol_map()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog'
AS $function$
declare
  v_started timestamptz := clock_timestamp();
begin
  refresh materialized view concurrently market.symbol_security;
  return jsonb_build_object(
    'rows', (select count(*) from market.symbol_security),
    'duration_ms', round(extract(epoch from clock_timestamp() - v_started) * 1000));
end;
$function$;
