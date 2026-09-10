CREATE OR REPLACE FUNCTION ingest.reap()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ingest', 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare n int;
begin
  with expired as (
    update ingest.task
       set status = 'backoff',
           last_outcome = 'lease_expired',
           next_due_at = now() + (select backoff from ingest.facet f where f.facet = task.facet),
           lease_id = null, lease_expires_at = null, updated_at = now()
     where status = 'leased' and lease_expires_at < now()
     returning run_id, facet
  )
  select count(*) into n from expired;

  update ingest.attempt a
     set finished_at = now(), outcome = 'lease_expired',
         error = coalesce(a.error, 'the run holding this attempt died without finishing it')
   where a.finished_at is null and a.started_at < now() - interval '10 minutes';
  return n;
end $function$;
