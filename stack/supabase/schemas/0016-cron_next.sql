CREATE OR REPLACE FUNCTION market.cron_next()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  n      integer;
  pos    integer;
  target text;
begin
  select count(*) into n from market.cron_resource where enabled;
  if n = 0 then
    return null;
  end if;

  update market.cron_cursor
     set position = (position + 1) % n, advanced_at = now()
   where only_row
  returning position into pos;

  select resource into target
    from (select resource, row_number() over (order by position) - 1 as rn
            from market.cron_resource where enabled) q
   where rn = pos;

  return target;
end $function$;
