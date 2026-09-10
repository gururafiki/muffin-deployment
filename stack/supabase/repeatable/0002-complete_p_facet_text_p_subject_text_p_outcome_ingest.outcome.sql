CREATE OR REPLACE FUNCTION ingest.complete(p_facet text, p_subject text, p_outcome ingest.outcome, p_asked_with text DEFAULT NULL::text, p_watermark date DEFAULT NULL::date, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ingest', 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare f ingest.facet%rowtype;
begin
  select * into f from ingest.facet where facet = p_facet;
  if not found then raise exception 'unknown facet %', p_facet; end if;

  if p_outcome = 'answered' then
    update ingest.task
       set status = 'fresh', next_due_at = now() + f.ttl, last_answered_at = now(),
           last_outcome = p_outcome, last_error = null, asked_with = coalesce(p_asked_with, asked_with),
           watermark = coalesce(p_watermark, watermark),
           lease_id = null, lease_expires_at = null, updated_at = now()
     where facet = p_facet and subject = p_subject;

  elsif p_outcome in ('dead_subject','unsupported_venue') then
    raise exception
      'a settled absence goes through ingest.mark_absent(), which requires the attempt that proves it';

  else
    -- throttled / transport / empty / parser_killed: back off and mark NOTHING. An empty answer is
    -- only ever evidence about a subject once it has been asked ALONE with the provider proven
    -- healthy, and that proof lives in `ingest.attempt`.
    update ingest.task
       set status = 'backoff', next_due_at = now() + f.backoff,
           last_outcome = p_outcome, last_error = left(p_error, 500),
           asked_with = coalesce(p_asked_with, asked_with),
           lease_id = null, lease_expires_at = null, updated_at = now()
     where facet = p_facet and subject = p_subject;
  end if;
end $function$;
