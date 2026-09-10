CREATE OR REPLACE FUNCTION ingest.cool_down(p_provider text, p_for interval DEFAULT NULL::interval)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ingest', 'pg_catalog', 'pg_temp'
AS $function$
declare b ingest.provider_budget%rowtype; until timestamptz;
begin
  select * into b from ingest.provider_budget where provider_code = p_provider for update;
  if not found then raise exception 'unknown provider %', p_provider; end if;
  until := now() + coalesce(p_for, b.cooldown);
  -- NEVER SHORTEN AN EXISTING COOLDOWN. Two runs meeting the same throttle would otherwise have the
  -- second one's shorter nap overwrite the first one's, and the pause a provider asked for is a
  -- floor, not a suggestion.
  until := greatest(until, coalesce(b.cooldown_until, until));
  update ingest.provider_budget set cooldown_until = until where provider_code = p_provider;
  return until;
end $function$;
