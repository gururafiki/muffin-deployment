CREATE OR REPLACE FUNCTION market.apply_nse_symbol_map(p_map jsonb)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare
  v_updated integer := 0;
begin
  if p_map is null or jsonb_typeof(p_map) <> 'object' then
    raise exception 'apply_nse_symbol_map expects a json object of isin -> nse symbol';
  end if;

  with pairs as (
    select upper(key) as isin, (value #>> '{}') as symbol
      from jsonb_each(p_map)
     -- A non-string value is a malformed entry, not a listing. Rejecting it here keeps one bad row
     -- from aborting the statement, which applies in a single transaction.
     where jsonb_typeof(value) = 'string'
       and length(value #>> '{}') > 0
  ),
  resolved as (
    select i.security_id, min(p.symbol) as symbol, count(distinct p.symbol) as rivals
      from market.security_identifier i
      join pairs p on p.isin = upper(i.value)
      join market.security s on s.security_id = i.security_id
     where i.kind_code = 'isin'
       -- SCOPED TO INDIA. An ISIN is globally unique, so this cannot currently mis-hit — but NSE
       -- lists only Indian companies, and a filer id is per (security, regulator): writing one for
       -- a security in another jurisdiction would advertise a filing route that does not exist.
       and s.country_iso2 = 'IN'
     group by i.security_id
  )
  insert into market.security_filer (security_id, source_code, filer_id, as_of)
  select r.security_id, 'nse', r.symbol, now()
    from resolved r
   -- Two symbols for one ISIN is not a tie to break with min(); NSE's list has none today, which
   -- is exactly when this costs nothing to assert.
   where r.rivals = 1
  on conflict (security_id, source_code) do update
    set filer_id = excluded.filer_id,
        as_of    = excluded.as_of
    -- IDEMPOTENT. Without this every run rewrites every row, and `history_walked_at` lives on this
    -- table — an unnecessary update is WAL for nothing on a resource that runs on a TTL.
    where market.security_filer.filer_id is distinct from excluded.filer_id;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$function$;
