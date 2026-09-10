CREATE OR REPLACE FUNCTION market.apply_cik_map(p_map jsonb)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare
  v_updated integer := 0;
begin
  if p_map is null or jsonb_typeof(p_map) <> 'object' then
    raise exception 'apply_cik_map expects a json object of ticker -> cik';
  end if;

  with pairs as (
    select upper(key) as ticker, (value #>> '{}')::integer as cik
      from jsonb_each(p_map)
     -- A ticker whose value is not a number is a malformed entry, not a filer. Rejecting it here
     -- keeps one bad row from aborting the statement — migrations and this function alike apply
     -- in a single transaction.
     where jsonb_typeof(value) = 'number'
  ),
  -- Every symbol a security may legitimately be keyed on, each carrying its precedence.
  candidates as (
    -- 1. The ticker identifier. What the function has always used; unchanged.
    select i.security_id, p.cik, 1 as precedence
      from market.security_identifier i
      join pairs p on p.ticker = upper(i.value)
     where i.kind_code = 'ticker'
    union all
    -- 2. The symbol a US venue actually lists the security under. Consulted only as a fallback.
    select l.security_id, p.cik, 2 as precedence
      from market.listing l
      join market.exchange e on e.exch_code = l.exch_code
      join pairs p on p.ticker = upper(l.symbol)
     where l.symbol is not null
       and e.country_iso2 = 'US'
  ),
  -- The best available precedence per security: a ticker match is never overruled by a listing.
  best as (
    select security_id, min(precedence) as precedence
      from candidates
     group by security_id
  ),
  resolved as (
    select c.security_id,
           min(c.cik)            as cik,
           count(distinct c.cik) as rivals
      from candidates c
      join best b
        on b.security_id = c.security_id
       and b.precedence  = c.precedence
     group by c.security_id
  )
  update market.security s
     set cik = r.cik
    from resolved r
   where r.security_id = s.security_id
     -- Two symbols pointing at two different companies is not a tie-break, it is a refusal.
     and r.rivals = 1
     -- IDEMPOTENT AND CHEAP TO RE-RUN. Without this every invocation rewrites every matched row,
     -- which is the WAL cost of a full table update on a resource that runs monthly for nothing.
     and s.cik is distinct from r.cik;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$function$;
