-- RESOLVING ONE SYMBOL SHOULD NOT COST 27,629 LATERAL LOOKUPS.
--
-- `market.security_symbol` is a view whose body is `coalesce(ticker, provider_symbol)` over two
-- LATERAL subqueries per security. Migration 096 stopped `price_series` evaluating it once per
-- PRICE ROW by materialising it in a CTE — which fixed a timeout and left a fixed cost behind:
-- every query still resolves ALL 27,629 symbols to answer a question about one.
--
-- Measured on the node with nothing else running, after the weekly backfill:
--
--   daily  chart for AAPL    260 ms
--   weekly chart for AAPL  1,382 ms      <- and it TIMED OUT for anon under ordinary load
--
-- The plan shows why: `Seq Scan on security (actual rows=27629)` with a `Limit` subplan run 27,629
-- times, before anything about AAPL is considered. That cost does not shrink when the answer is
-- small, and it grows with the universe — the daily chart is already spending most of its 260 ms
-- there.
--
-- ── A MATERIALISED VIEW WITH AN INDEX ON THE SYMBOL ─────────────────────────────────────────
--
-- The mapping changes only when a security gains or corrects a symbol, which is a backlog's work
-- and not a per-request concern. Materialising it turns the lateral scan into an index seek and
-- makes the cost proportional to the ANSWER rather than to the universe.
--
-- REFRESHED BESIDE `security_facets`, by the same resource, deliberately: a materialised view with
-- no scheduled refresh is a stale view nobody notices, and the facets refresh already runs on the
-- cron. `symbol_security_id_idx` is UNIQUE because `refresh ... concurrently` requires one — and
-- concurrently is what keeps readers unblocked during the rebuild.
--
-- The symbol is NOT unique: two securities can resolve to the same string (a ticker reused across
-- venues), and a unique index there would fail the refresh rather than the insert that caused it.

do $$
declare kind char;
begin
  -- `IF EXISTS` does not protect against a relkind mismatch: `drop view` on a matview raises
  -- `"x" is not a view` and the reverse raises the converse, so NEITHER ordering is safe.
  select relkind into kind from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'symbol_security';
  if kind = 'v' then execute 'drop view market.symbol_security cascade';
  elsif kind = 'm' then execute 'drop materialized view market.symbol_security cascade';
  end if;
end $$;

create materialized view market.symbol_security as
select s.security_id, sym.symbol
from market.security s
join market.security_symbol sym on sym.security_id = s.security_id
where sym.symbol is not null;

create unique index if not exists symbol_security_id_idx on market.symbol_security (security_id);
create index if not exists symbol_security_symbol_idx on market.symbol_security (symbol);

comment on materialized view market.symbol_security is
  'symbol -> security_id, materialised. `security_symbol` is a view over two LATERAL subqueries, so resolving one symbol through it costs a scan of all 27,629 securities — measured, that is most of the 260 ms a daily chart takes and 1,382 ms of a weekly one. Refreshed beside security_facets by the same resource, because a matview with no scheduled refresh is a stale view nobody notices.';

grant select on market.symbol_security to anon, authenticated, service_role;

-- ── the serving view, now an index seek ──────────────────────────────────────────────────────
drop view if exists market.price_series;

create view market.price_series as
select distinct on (symbol, grain, date) symbol, date, close, grain
from (
  select ss.symbol, sp.date, sp.close, sp.grain, 1 as priority
  from market.security_price sp
  join market.symbol_security ss on ss.security_id = sp.security_id
  union all
  select p.symbol, p.date, p.close, 'daily'::text as grain, 2 as priority
  from market.prices p
) x
order by symbol, grain, date, priority;

comment on view market.price_series is
  'Every close the app can chart, by symbol and GRAIN: the security series first, the curated instrument series second. Joins the MATERIALISED symbol map — through the `security_symbol` view the planner scans all 27,629 securities to answer about one, which timed out for anon on the weekly series. A reader must filter on `grain` (the two overlap by design) and page (a 20-year weekly series is 1,077 rows, above PGRST_DB_MAX_ROWS).';

grant select on market.price_series to anon, authenticated, service_role;

-- ── refreshed with the facets spine ──────────────────────────────────────────────────────────
drop function if exists market.refresh_facets();

create function market.refresh_facets()
returns table (rows_refreshed bigint, refreshed_at timestamptz)
language plpgsql
security definer
set search_path = market, pg_catalog
as $$
begin
  -- THE SYMBOL MAP FIRST. `security_facets` is what the screener reads and the symbol map is what
  -- every chart reads; refreshing them in one call is what stops the second one being forgotten.
  refresh materialized view concurrently market.symbol_security;
  refresh materialized view concurrently market.security_facets;
  return query
    select count(*)::bigint, max(f.refreshed_at) from market.security_facets f;
end;
$$;

revoke execute on function market.refresh_facets() from public;
grant execute on function market.refresh_facets() to service_role;

notify pgrst, 'reload schema';
