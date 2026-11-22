CREATE OR REPLACE FUNCTION market.clear_symbol_caches(p_security_id uuid)
 RETURNS void
 LANGUAGE sql
AS $function$
  update market.security set
    corporate_actions_missing_at = null
  where security_id = p_security_id;
$function$;
