CREATE OR REPLACE FUNCTION market.sample_backlog(p_backlog text, p_sampled_at timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  n  bigint;
  t0 timestamptz := clock_timestamp();
begin
  -- Only a discovered backlog, so this cannot be turned into "count any relation you name" by a
  -- caller. It is SECURITY DEFINER and reachable over the API by service_role.
  if not exists (select 1 from market.backlogs_to_sample() b where b = p_backlog) then
    raise exception 'not a backlog: %', p_backlog;
  end if;

  execute format('select count(*) from market.%I', p_backlog) into n;

  insert into market.backlog_sample (sampled_at, backlog, depth, duration_ms, error)
       values (p_sampled_at, p_backlog, n,
               extract(epoch from clock_timestamp() - t0) * 1000, null)
  on conflict (sampled_at, backlog) do update
     set depth = excluded.depth, duration_ms = excluded.duration_ms, error = null;

  return n;
end $function$;
