CREATE OR REPLACE FUNCTION market.security_statement_requeue()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- A CORRECTED CURRENCY RE-DERIVES TOO: the metrics carry the statement's currency, so a row
  -- relabelled after it was derived would otherwise keep serving the old (or withheld) label.
  if new.as_of is distinct from old.as_of or new.data is distinct from old.data
     or new.currency is distinct from old.currency then
    new.derived_at := null;
  end if;
  return new;
end;
$function$;
