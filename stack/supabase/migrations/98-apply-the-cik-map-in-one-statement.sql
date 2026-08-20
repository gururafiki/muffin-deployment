-- A PAGE THAT RESTARTS FROM ZERO IS NOT A PAGE — second instance, new resource.
--
-- `sec-cik-map` fetched SEC's 10,387-filer list in 0.18s and then spent its whole worker updating
-- `security.cik` ONE ROW AT A TIME. Measured on the first real run:
--
--   {"resource":"sec-cik-map","filers":10387,"scanned":6645,"matched":3516}
--
-- 6,645 of ~27,000 ticker identifiers before the deadline — and because the scan restarts at
-- `range(0, 999)` every run, the next invocation redoes the same 6,645 and stops in the same
-- place. It would never reach the rest, while reporting 3,516 matches as if it were progress.
-- Same shape as `derive_security_metrics`' first version, and the same tell: a number that looks
-- like throughput and does not move.
--
-- The fix is not a cursor. The whole map is 776 KB and the join is a join: hand it to Postgres
-- once and let it do the work in a single statement, which is both correct and ~27,000 times fewer
-- round trips.

create or replace function market.apply_cik_map(p_map jsonb)
returns integer
language plpgsql
as $$
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
  )
  update market.security s
     set cik = p.cik
    from market.security_identifier i
    join pairs p on p.ticker = upper(i.value)
   where i.security_id = s.security_id
     and i.kind_code = 'ticker'
     -- IDEMPOTENT AND CHEAP TO RE-RUN. Without this every invocation rewrites every matched row,
     -- which is the WAL cost of a full table update on a resource that runs monthly for nothing.
     and s.cik is distinct from p.cik;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

comment on function market.apply_cik_map(jsonb) is
  'Applies SEC''s ticker -> CIK map in ONE statement. The row-at-a-time version reached 6,645 of ~27,000 identifiers before its deadline and restarted from zero every run, so it could never reach the rest while reporting matches as progress.';

revoke execute on function market.apply_cik_map(jsonb) from public;
grant execute on function market.apply_cik_map(jsonb) to service_role;

notify pgrst, 'reload schema';
