CREATE OR REPLACE FUNCTION ingest.claim(p_facet text, p_limit integer, p_lease interval, p_run_id text)
 RETURNS SETOF ingest.task
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ingest', 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare v_lease uuid := gen_random_uuid();
begin
  perform ingest.reap();
  return query
  with picked as (
    select t.facet, t.subject
      from ingest.task t
     where t.facet = p_facet
       and t.status in ('due','backoff')
       and t.next_due_at <= now()
     order by t.round, t.priority desc, t.subject
     limit p_limit
       for update skip locked
  )
  update ingest.task t
     set status = 'leased', lease_id = v_lease, lease_expires_at = now() + p_lease,
         run_id = p_run_id, attempts = t.attempts + 1, last_asked_at = now(), updated_at = now()
    from picked p
   where t.facet = p.facet and t.subject = p.subject
  returning t.*;
end $function$;
