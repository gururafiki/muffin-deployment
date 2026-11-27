CREATE OR REPLACE FUNCTION market.cron_scheduled_resources()
 RETURNS SETOF text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
begin
  if to_regclass('cron.job') is null then
    return;
  end if;
  return query execute $q$
    select distinct (regexp_match(j.command, 'cron_post\(''([a-z0-9-]+)''\)'))[1]
      from cron.job j
     where j.active
       and j.command ~ 'cron_post\('''
  $q$;
end;
$function$;
