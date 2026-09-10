CREATE OR REPLACE FUNCTION ingest.mark_absent(p_facet text, p_subject text, p_attempt_id bigint, p_asked_with text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ingest', 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare f ingest.facet%rowtype; a ingest.attempt%rowtype;
begin
  select * into f from ingest.facet where facet = p_facet;
  if not found then raise exception 'unknown facet %', p_facet; end if;

  select * into a from ingest.attempt where attempt_id = p_attempt_id;
  if not found then raise exception 'no attempt % to justify marking % absent', p_attempt_id, p_subject; end if;
  if not a.isolated then
    raise exception
      'refusing to mark % absent: attempt % did not ask it ALONE, and a run-wide tally is never evidence about one subject',
      p_subject, p_attempt_id;
  end if;
  if a.control_answered is distinct from true then
    raise exception
      'refusing to mark % absent: attempt % did not prove the provider healthy with a control subject',
      p_subject, p_attempt_id;
  end if;

  -- MARKING MUST RETRACT. The mark excludes the subject from the backlog, so nothing else will ever
  -- remove the stale number it stops producing.
  if f.retract_sql is not null then
    execute f.retract_sql using p_subject;
    update ingest.attempt set rows_retracted = rows_retracted + 1 where attempt_id = p_attempt_id;
  end if;

  update ingest.task
     set status = 'absent', next_due_at = now() + f.absent_ttl,
         last_outcome = a.outcome, asked_with = coalesce(p_asked_with, asked_with),
         lease_id = null, lease_expires_at = null, updated_at = now()
   where facet = p_facet and subject = p_subject;
end $function$;
