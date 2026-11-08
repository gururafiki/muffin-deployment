CREATE OR REPLACE FUNCTION market.venue_listing_keeps_its_latest_sighting()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
begin
  -- `greatest` ignores a null, so an alias page (no venue sighting) keeps the stored one.
  new.last_seen_at  := greatest(old.last_seen_at, new.last_seen_at);
  new.venue_seen_at := greatest(old.venue_seen_at, new.venue_seen_at);
  if old.absent_since is not null
     and new.venue_seen_at > coalesce(old.venue_seen_at, '-infinity'::timestamptz)
     and new.venue_seen_at > old.absent_since then
    new.absent_since := null;
  else
    new.absent_since := old.absent_since;
  end if;
  return new;
end;
$function$;
