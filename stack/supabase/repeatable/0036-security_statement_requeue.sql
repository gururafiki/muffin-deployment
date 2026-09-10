CREATE OR REPLACE FUNCTION market.security_statement_requeue()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.as_of is distinct from old.as_of or new.data is distinct from old.data then
    new.derived_at := null;
  end if;
  return new;
end;
$function$;
