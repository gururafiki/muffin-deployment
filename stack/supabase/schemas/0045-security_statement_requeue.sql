CREATE OR REPLACE FUNCTION market.security_statement_requeue()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- A CORRECTED CURRENCY RE-DERIVES TOO: the metrics carry the statement's currency, so a row
  -- relabelled after it was derived would otherwise keep serving the old (or withheld) label.
  -- So does a new FISCAL LABEL, which the metrics carry the same way.
  if new.as_of is distinct from old.as_of or new.data is distinct from old.data
     or new.currency is distinct from old.currency
     or new.fiscal_year is distinct from old.fiscal_year
     or new.fiscal_period is distinct from old.fiscal_period then
    new.derived_at := null;
  end if;
  return new;
end;
$function$;
