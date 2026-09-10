CREATE OR REPLACE FUNCTION market.source_priority(p_code text)
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce((select priority from market.data_source where code = p_code), 0);
$function$;
