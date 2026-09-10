CREATE OR REPLACE FUNCTION market.backlogs_to_sample()
 RETURNS SETOF text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
  select c.relname
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'market'
     and c.relkind in ('v', 'm')
     and c.relname like 'pending\_%'
   order by c.relname
$function$;
