-- D2: the serving layer moves to the new tables, and the old resources stop.
--
-- ONE MIGRATION, NOT TWO STEPS, and that is forced rather than chosen. `security-performance`,
-- `instrument-performance` and the three group/country/sector resources all `upsert` into
-- `market.performance`; a view without an `INSTEAD OF` trigger rejects an insert. Convert first and
-- they crash; disable first and nothing maintains the table the app is still reading. So the
-- conversion and `enabled = false` land together.
--
-- Rehearsed in full against the real database in a rolled-back transaction before it was written
-- (design 8.7): all five dependents rebuilt, 0 missing, and as `anon` 21 ms / 89 ms / 15 ms / 1 ms.

-- ── 1. price_series: already a VIEW, so a plain redefinition ───────────────────────────────────
--
-- EACH ARM NAMES THE BASE TABLES ITSELF. A shared CTE is referenced twice and therefore
-- MATERIALISED, so all 17 M rows were joined to `symbol_security` before either arm's `symbol =`
-- predicate could apply: 23,871 ms against 13 ms. Measured, after I first blamed the weekly
-- `distinct on` and was wrong.
create or replace view market.price_series as
select ss.symbol, pb.trade_date as date, pb.close, 'daily'::text as grain
  from market.price_bar pb
  join market.symbol_security ss on ss.security_id = pb.security_id
union all
-- ITS OWN SUBQUERY: in a set-operation arm `ORDER BY` resolves against the OUTPUT columns, so
-- `distinct on (…, trade_date)` beside `trade_date as date` fails with `column "trade_date" does
-- not exist`.
select symbol, date, close, 'weekly'::text as grain
  from (
    select distinct on (ss.symbol, date_trunc('week', pb.trade_date))
           ss.symbol, pb.trade_date as date, pb.close
      from market.price_bar pb
      join market.symbol_security ss on ss.security_id = pb.security_id
     order by ss.symbol, date_trunc('week', pb.trade_date), pb.trade_date desc
  ) w;

-- ── 2. performance: a TABLE with dependents, so drop-and-recreate ──────────────────────────────
do $$
declare r record; kind "char"; remaining int; last_err text;
begin
  select relkind into kind from pg_class where oid = 'market.performance'::regclass;

  -- RELKIND-AWARE, because `drop table if exists` RAISES on a view and `drop view if exists`
  -- raises on a table — neither ordering is safe, and migrations re-run on every deploy.
  if kind <> 'r' then
    raise notice 'performance is already a view; nothing to convert';
    return;
  end if;

  -- CAPTURE BEFORE THE CASCADE, which does not give them back — the DEFINITION *and* the ACL.
  -- `drop` loses the grants, and CI said so on the first run: `anon cannot read 4 serving view(s)`.
  -- Emitted from `relacl` rather than from a list of expected roles, because `anon`,
  -- `authenticated`, `service_role`, `metrics_ro` and `ingest_rw` do not hold the same privileges
  -- on the same objects, and a hand-written list is the shape that rots.
  --
  -- `distinct on` because pg_depend carries a row per REFERENCED COLUMN: the five dependents
  -- arrive as eighteen rows, which made the notice below report eighteen rebuilds. Deduped on the
  -- name rather than with a bare `distinct`, since `aclitem[]` has no btree opclass to sort on.
  create temp table saved_defs on commit drop as
  select distinct on (dependent.relname)
         dependent.relname::text as name, pg_get_viewdef(dependent.oid, true) as def,
         dependent.relkind as rk, dependent.relacl as acl
    from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid
    join pg_class dependent on dependent.oid = rw.ev_class
   where d.refobjid = 'market.performance'::regclass and dependent.relname <> 'performance'
   order by dependent.relname;

  drop table market.performance cascade;

  execute $v$
    create view market.performance as
    -- INSTRUMENT is keyed by the DISPLAY symbol. Migration 39 re-keyed `scope_id` deliberately,
    -- and anything joining this on `security_id` reports zero coverage.
    select 'instrument'::text as scope,
           sym.symbol                                  as scope_id,
           sr.period_code                              as period,
           sr.price_return_pct                         as change_pct,
           sr.as_of::timestamptz                       as as_of,
           -- Only `pending_performance` reads this, and that view is the OLD resource's backlog
           -- and retires with it. Supplied so the replacement stays drop-in until then.
           (sr.as_of + interval '1 day')::timestamptz   as stale_after,
           sr.source_code                              as source,
           sr.total_return_pct
      from market.security_return sr
      join market.security_symbol sym on sym.security_id = sr.security_id
    union all
    -- COUNTRY / GROUP / SECTOR share one table keyed `<scope>:<scope_id>`, and a group's id is
    -- itself `<scheme>:<group>` — so the split is on the FIRST colon only.
    select split_part(ir.index_code, ':', 1),
           substr(ir.index_code, position(':' in ir.index_code) + 1),
           ir.period_code, ir.price_return_pct,
           ir.as_of::timestamptz, (ir.as_of + interval '1 day')::timestamptz,
           ir.source_code, ir.total_return_pct
      from market.index_return ir
  $v$;

  -- Rebuild the dependents from their own captured definitions, retrying so that one depending on
  -- another is created after it rather than by guessing an order.
  for i in 1..6 loop
    remaining := 0;
    for r in select * from saved_defs loop
      begin
        if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                        where c.relname = r.name and n.nspname = 'market') then
          execute format('create %s market.%I as %s',
                         case r.rk when 'm' then 'materialized view' else 'view' end, r.name, r.def);
        end if;
      exception when others then remaining := remaining + 1; last_err := sqlerrm;
      end;
    end loop;
    exit when remaining = 0;
  end loop;
  if remaining > 0 then
    raise exception 'could not rebuild % dependent(s) of market.performance: %', remaining, last_err;
  end if;

  -- RE-ISSUE THE CAPTURED GRANTS. A rebuilt view with no ACL is unreadable by the app while
  -- looking perfectly correct to a superuser probe — the same shape as the PGRST205 schema-cache
  -- incident, and as `security_facets` coming back without the UNIQUE index that lets it refresh
  -- concurrently.
  for r in select s.name, a.grantee, a.privilege_type
             from saved_defs s, lateral aclexplode(s.acl) a
            where s.acl is not null loop
    execute format('grant %s on market.%I to %s', r.privilege_type, r.name,
                   case when r.grantee = 0 then 'public'
                        else quote_ident((select rolname from pg_roles where oid = r.grantee)) end);
  end loop;

  raise notice 'performance converted to a view and % dependent(s) rebuilt',
               (select count(*) from saved_defs);
end $$;

-- `drop table` takes the ACL with it, and every read here is anon's.
grant select on market.performance, market.price_series to anon, authenticated, service_role;

-- ── 3. the old resources stop ──────────────────────────────────────────────────────────────────
--
-- Unconditional rather than one-shot: this is a RETIREMENT, so a re-enabled row is drift to be
-- corrected on the next deploy, not a choice to be preserved.
--
-- RETIRES: security-prices, security-daily-history, security-price-history, security-performance
-- RETIRES: instrument-prices, instrument-performance, sector-performance, country-performance
-- RETIRES: group-performance, fx-rates
--
-- The marker is read by `logic-check.ts`. Its rotation guard requires a disabled resource to have
-- its own pg_cron job, because migration 137 moved four pure-SQL resources that way and a
-- disabled-and-unscheduled resource is normally a resource that silently stopped running. A
-- RETIRED one is disabled-and-gone on purpose, and without saying so these ten failed a check that
-- was working correctly.
update market.cron_resource set enabled = false
 where resource in ('security-prices','security-daily-history','security-price-history',
                    'security-performance','instrument-prices','instrument-performance',
                    'sector-performance','country-performance','group-performance','fx-rates');
