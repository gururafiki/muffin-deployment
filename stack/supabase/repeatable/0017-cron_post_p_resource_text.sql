CREATE OR REPLACE FUNCTION market.cron_post(p_resource text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare key text; base text;
begin
  if p_resource is null then return 'no enabled resources'; end if;

  select decrypted_secret into key  from vault.decrypted_secrets where name = 'service_role_key';
  select decrypted_secret into base from vault.decrypted_secrets where name = 'functions_base_url';
  if key is null or key = '' or base is null or base = '' then
    return 'vault secrets missing — nothing posted for ' || p_resource;
  end if;

  perform net.http_post(
    url     := base || '/market-refresh',
    body    := jsonb_build_object('resource', p_resource),
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'apikey',        key,
                 'Authorization', 'Bearer ' || key),
    timeout_milliseconds := 120000
  );
  return p_resource;
end $function$;
