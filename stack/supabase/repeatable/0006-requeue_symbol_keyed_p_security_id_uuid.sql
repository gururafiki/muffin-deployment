CREATE OR REPLACE FUNCTION ingest.requeue_symbol_keyed(p_security_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ingest', 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare n int;
begin
  with cleared as (
    update ingest.task t
       set status = 'due', next_due_at = now(), last_outcome = null, updated_at = now()
      from ingest.facet f
     where f.facet = t.facet
       and f.key_kind = 'symbol'
       and t.security_id = p_security_id
       and t.status = 'absent'
    returning 1
  ) select count(*) into n from cleared;
  return n;
end $function$;
