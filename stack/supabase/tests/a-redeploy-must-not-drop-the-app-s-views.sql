-- RE-APPLYING A MIGRATION MUST NOT TAKE THE APP'S VIEWS OFFLINE.
--
-- Migration 035 discovers everything built on `security_symbol` via `pg_depend` and cascade-drops
-- it, so that the view can be rebuilt. That is correct — a hand-maintained list was wrong three
-- times in one afternoon — but the dependents are recreated by the migrations that OWN them, which
-- run far later in the pass: `pending_dividends` in 087, `pending_symbol_repair` in 101,
-- `price_series` and `symbol_security` in 102, `security_metric_series` in 126.
--
-- Each migration file is its own transaction. So between the drop and those creates the views
-- genuinely do not exist — roughly seventy files of wall-clock, on EVERY deploy, several times a
-- day. Measured 2026-08-27: three resources failed inside 61 seconds with
-- `relation "market.pending_*" does not exist`, and they were merely the ones whose five-minute
-- tick landed inside the window. `price_series` and `security_metric_series` are in the same
-- cascade, and they are what the stock page's chart and statement tables read.
--
-- Nothing reported it, because a reader that 404s is not a migration failure: every pass was green.
--
-- The fix is that 035 tries `create or replace view` first and only cascades when Postgres refuses
-- — which it does exactly when columns are renamed, reordered or dropped. This test is the guard:
-- a re-apply with an UNCHANGED definition must leave dependents standing.

\set ON_ERROR_STOP on

begin;

-- A stand-in for `price_series` and friends: something that depends on `security_symbol` and is
-- created by a LATER migration than 035, so a cascade would remove it and nothing in 035 would
-- put it back.
create view market.zz_depends_on_symbol as
  select security_id, symbol from market.security_symbol;

do $$
declare
  present boolean;
  ddl constant text := $ddl$
select
  s.security_id,
  coalesce(t.value, ps.symbol) as symbol
from market.security s
left join lateral (
  select i.value
  from market.security_identifier i
  where i.security_id = s.security_id and i.kind_code = 'ticker'
  order by i.value
  limit 1
) t on true
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
where coalesce(t.value, ps.symbol) is not null
$ddl$;
begin
  -- Exactly what migration 035 now does on a re-run: replace in place. The definition is
  -- byte-identical to the one it ships, so this must succeed WITHOUT touching dependents.
  execute 'create or replace view market.security_symbol as ' || ddl;

  select exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'market' and c.relname = 'zz_depends_on_symbol'
  ) into present;

  if not present then
    raise exception
      'RE-APPLYING security_symbol DROPPED A DEPENDENT. That is a user-visible outage on every '
      'deploy: `price_series` and `security_metric_series` are in the same cascade and are what '
      'the stock page reads, and they are not recreated until migrations 102 and 126 — about '
      'seventy files later, each its own transaction.';
  end if;
  raise notice '  ok  an unchanged security_symbol replaces in place, dependents survive';
end $$;

-- ...AND THE CASCADE MUST STILL BE REACHABLE. A fix that simply never drops anything would pass
-- the assertion above and break the one case the drop exists for: Postgres refuses to REPLACE a
-- view whose columns are reordered, and that refusal is what triggers the rebuild.
do $$
declare refused boolean := false;
begin
  begin
    execute $bad$create or replace view market.security_symbol as
      select coalesce(t.value, ps.symbol) as symbol, s.security_id
        from market.security s
        left join lateral (select i.value from market.security_identifier i
                            where i.security_id = s.security_id and i.kind_code = 'ticker'
                            order by i.value limit 1) t on true
        left join market.security_provider_symbol ps
          on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
       where coalesce(t.value, ps.symbol) is not null$bad$;
  exception when others then
    refused := true;
  end;

  if not refused then
    raise exception
      'Postgres ACCEPTED a column reorder on `create or replace view`. The whole fix rests on it '
      'refusing — if it does not, 035 would silently never rebuild dependents after a real shape '
      'change, which is worse than the window this replaced.';
  end if;
  raise notice '  ok  a reordered column list is still refused, so the cascade remains reachable';
end $$;

rollback;
