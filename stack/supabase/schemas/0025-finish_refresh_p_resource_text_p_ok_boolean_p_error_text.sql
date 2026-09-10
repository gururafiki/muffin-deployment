CREATE OR REPLACE FUNCTION market.finish_refresh(p_resource text, p_ok boolean, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_temp'
AS $function$
  update market.refresh_log
     set finished_at = now(), ok = p_ok, error = p_error
   where resource = p_resource;
$function$;
