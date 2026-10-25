CREATE OR REPLACE FUNCTION market.venue_listing_keeps_its_latest_sighting()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
begin
  if new.last_seen_at > old.last_seen_at then
    new.absent_since := null;
  else
    new.last_seen_at := old.last_seen_at;
    new.absent_since := old.absent_since;
  end if;
  return new;
end;
$function$;
