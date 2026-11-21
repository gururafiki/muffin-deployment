-- The Dagster news lane runs as `ingest_rw` and prunes with `market.prune_news`, which the baseline
-- revoked from PUBLIC (migration 20261122100000). Without the grant the lane's first run would fail
-- after writing its articles, and the 90-day window would stop being enforced.

\set ON_ERROR_STOP on

do $$
begin
  if not has_function_privilege('ingest_rw', 'market.prune_news(integer)', 'EXECUTE') then
    raise exception 'ingest_rw cannot execute market.prune_news, so the news lane cannot prune';
  end if;
  if has_function_privilege('anon', 'market.prune_news(integer)', 'EXECUTE') then
    raise exception 'anon may execute market.prune_news: the grant must name the worker only';
  end if;
  raise notice 'ok  the news lane can prune, and only the worker';
end $$;
