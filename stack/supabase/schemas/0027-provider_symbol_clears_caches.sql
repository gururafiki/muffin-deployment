CREATE OR REPLACE FUNCTION market.provider_symbol_clears_caches()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_temp'
AS $function$
begin
  if tg_op = 'UPDATE' and old.symbol is not distinct from new.symbol then
    return null;
  end if;
  perform market.clear_symbol_caches(new.security_id);
  return null;
end $function$;
