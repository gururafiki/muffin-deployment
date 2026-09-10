CREATE OR REPLACE FUNCTION market.prune_observability(p_days integer DEFAULT 400)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  cutoff timestamptz := now() - make_interval(days => p_days);
  n integer := 0; d integer;
begin
  delete from market.refresh_run     where started_at < cutoff;  get diagnostics d = row_count; n := n + d;
  delete from market.backlog_sample  where sampled_at < cutoff;  get diagnostics d = row_count; n := n + d;
  delete from market.universe_sample where sampled_at < cutoff;  get diagnostics d = row_count; n := n + d;
  delete from market.coverage_sample where sampled_at < cutoff;  get diagnostics d = row_count; n := n + d;
  return n;
end $function$;
