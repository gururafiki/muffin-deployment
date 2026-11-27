CREATE OR REPLACE FUNCTION market.sync_sec_filer()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog'
AS $function$
begin
  if new.cik is not null then
    insert into market.security_filer (security_id, source_code, filer_id, via)
         values (new.security_id, 'sec', new.cik::text, 'registry')
    on conflict (security_id, source_code) do update
       set filer_id = excluded.filer_id, via = 'registry';
  else
    -- A CLEARED CIK MUST RETRACT. Leaving the row would keep the security reading `held` against a
    -- registration we no longer believe in, and an upsert cannot retract. Only the CIK's OWN row:
    -- a sibling row was never claimed by the CIK.
    delete from market.security_filer
     where security_id = new.security_id and source_code = 'sec' and via = 'registry';
  end if;
  return new;
end $function$;
