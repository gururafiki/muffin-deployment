CREATE OR REPLACE FUNCTION market.set_debt_terms(p_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_temp'
AS $function$
declare
  n integer;
begin
  update market.security s
     set maturity_date    = r.maturity_date,
         coupon_rate      = r.coupon_rate,
         coupon_kind_code = r.coupon_kind_code,
         in_default       = r.in_default,
         debt_terms_as_of = r.as_of
    from jsonb_to_recordset(p_rows) as r(
           security_id uuid,
           maturity_date date,
           coupon_rate numeric,
           coupon_kind_code text,
           in_default boolean,
           as_of timestamptz
         )
   where s.security_id = r.security_id
     -- NEVER let an older filing overwrite a newer one. Funds are ingested in whatever order the
     -- backlog offers, and two funds holding the same bond file at different quarter-ends, so
     -- without this the stored terms would flap depending on which fund ran last.
     and (s.debt_terms_as_of is null or r.as_of >= s.debt_terms_as_of);

  get diagnostics n = row_count;
  return n;
end $function$;
