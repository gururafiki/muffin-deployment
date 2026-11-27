CREATE OR REPLACE FUNCTION market.cron_tick()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
begin
  return market.cron_post(market.cron_next());
end $function$;
