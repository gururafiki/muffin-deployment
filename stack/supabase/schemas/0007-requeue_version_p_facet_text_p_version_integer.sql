CREATE OR REPLACE FUNCTION ingest.requeue_version(p_facet text, p_version integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ingest', 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare n int;
begin
  with bumped as (
    update ingest.task
       set status = 'due', next_due_at = now(), version = p_version, updated_at = now()
     where facet = p_facet and version < p_version
    returning 1
  ) select count(*) into n from bumped;
  return n;
end $function$;
