CREATE OR REPLACE FUNCTION ingest.spend(p_provider text, p_n integer DEFAULT 1)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ingest', 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare b ingest.provider_budget%rowtype;
begin
  select * into b from ingest.provider_budget where provider_code = p_provider for update;
  if not found then raise exception 'unknown provider %', p_provider; end if;
  if not b.enabled then return false; end if;
  if b.cooldown_until is not null and b.cooldown_until > now() then return false; end if;

  if b.quota_day < current_date then
    update ingest.provider_budget set used_today = 0, quota_day = current_date
     where provider_code = p_provider;
    b.used_today := 0;
  end if;

  if b.daily_quota is not null and b.used_today + p_n > b.daily_quota then return false; end if;

  update ingest.provider_budget set used_today = used_today + p_n where provider_code = p_provider;
  return true;
end $function$;
