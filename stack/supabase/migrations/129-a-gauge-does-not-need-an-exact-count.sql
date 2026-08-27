-- A GAUGE DOES NOT NEED AN EXACT COUNT, AND A WARM CACHE IS NOT A MEASUREMENT.
--
-- Migration 127 counted every market table exactly, on the strength of a measurement taken on the
-- node: "771 ms for all 63, `security_price` at 10,874,625 rows included". `sample_universe` then
-- timed out in production at 8s, and re-measuring gave the real picture:
--
--     count(*) over every market table      10,252 ms      <-- 771 ms when warm
--     pg_total_relation_size over each           6 ms
--     the %_missing_at populations              86 ms
--
-- THE FIRST NUMBER WAS TAKEN OFF A WARM BUFFER CACHE. `count(*)` on a 10.9M-row table is a full
-- scan; from shared buffers it is 266 ms and off disk it is seconds. Nothing had grown — the
-- deploy had simply evicted the cache. A measurement taken once, warm, measures that moment.
--
-- And the exactness bought nothing. This is a GAUGE, plotted to answer "is the universe growing".
-- `pg_class.reltuples` is maintained by autovacuum, costs a catalogue lookup, and is accurate to a
-- few percent — invisible on a chart of ten million. So the row counts become estimates and SAY SO
-- in the metric name: a series called `rows.security_price` that is not the row count is the kind
-- of quiet inaccuracy this schema has been bitten by repeatedly.
--
-- The counts `market-verify.yml` asserts FLOORS on stay EXACT (`equities`, `identifiers.*`,
-- `tracked_funds.*`). They are small, they are what a human compares against the nightly gate, and
-- a dashboard that disagrees with the gate is worse than no dashboard.

create or replace function market.sample_universe()
returns integer
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  r     record;
  n     bigint;
  ts    timestamptz := now();
  taken integer := 0;
begin
  perform set_config('statement_timeout', '30s', true);

  -- ESTIMATED rows, exact on-disk size. `reltuples` is -1 for a relation never analysed (Postgres
  -- 14+ distinguishes that from a genuine zero), so it is skipped rather than recorded as -1.
  for r in
    select c.relname                     as tbl,
           c.reltuples                   as est,
           pg_total_relation_size(c.oid) as bytes
      from pg_class c
      join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'market' and c.relkind = 'r'
     order by c.relname
  loop
    if r.est >= 0 then
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, 'rows_estimate.' || r.tbl, r.est)
      on conflict do nothing;
      taken := taken + 1;
    end if;
    insert into market.universe_sample (sampled_at, metric, value)
         values (ts, 'bytes.' || r.tbl, r.bytes)
    on conflict do nothing;
    taken := taken + 1;
  end loop;

  -- EXACT, and they have to be: a 20% jump is the alert, and an estimate's error bar is wider
  -- than that. 86 ms for all twenty.
  for r in
    select c.relname as tbl, a.attname as col
      from pg_class c
      join pg_namespace ns on ns.oid = c.relnamespace
      join pg_attribute a  on a.attrelid = c.oid
     where ns.nspname = 'market' and c.relkind = 'r'
       and a.attnum > 0 and not a.attisdropped
       and a.attname like '%\_missing\_at'
     order by c.relname, a.attname
  loop
    begin
      execute format('select count(*) from market.%I where %I is not null', r.tbl, r.col) into n;
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, format('missing.%s.%s', r.tbl, r.col), n)
      on conflict do nothing;
      taken := taken + 1;
    exception when others then null;
    end;
  end loop;

  -- EXACT, because market-verify.yml asserts floors on exactly these.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, m, v from (
    select 'equities' as m, count(*)::numeric as v from market.security where security_type_code = 'equity'
    union all
    select 'identifiers.isin',   count(*) from market.security_identifier where kind_code = 'isin'
    union all
    select 'identifiers.ticker', count(*) from market.security_identifier where kind_code = 'ticker'
    union all
    select 'identifiers.cusip',  count(*) from market.security_identifier where kind_code = 'cusip'
    union all
    select 'tracked_funds.enabled',  count(*) from market.tracked_fund where enabled = true
    union all
    select 'tracked_funds.ingested', count(*) from market.tracked_fund where last_report_date is not null
  ) s
  on conflict do nothing;

  return taken + 6;
end $$;

-- === A backlog too slow to count exactly ======================================================
--
-- `pending_prices` was 5,380 ms when 127 was written and is now past 8s, so the first production
-- sweep recorded `depth NULL, error 'canceling statement due to statement timeout'`. That is
-- HONEST — NULL is not zero, and a backlog that has begun timing out must not read as drained —
-- but it is not useful: the one queue big enough to matter is the one with no number.
--
-- The planner already holds an estimate and charges nothing for it, so a caller that has just been
-- timed out asks again for that, and the row SAYS which it got. A number you can trend, flagged as
-- an estimate, beats an empty panel and beats a precise number nobody can obtain.
--
-- Only a fallback: the exact count is tried first and wins whenever it fits.
alter table market.backlog_sample add column if not exists estimated boolean not null default false;

create or replace function market.sample_backlog_estimate(
  p_backlog    text,
  p_sampled_at timestamptz
) returns bigint
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare
  plan jsonb;
  n    bigint;
  t0   timestamptz := clock_timestamp();
begin
  if not exists (select 1 from market.backlogs_to_sample() b where b = p_backlog) then
    raise exception 'not a backlog: %', p_backlog;
  end if;

  -- EXPLAIN without ANALYZE: the planner's estimate. No execution, no scan.
  execute format('explain (format json) select 1 from market.%I', p_backlog) into plan;
  n := (plan -> 0 -> 'Plan' ->> 'Plan Rows')::bigint;

  insert into market.backlog_sample (sampled_at, backlog, depth, duration_ms, error, estimated)
       values (p_sampled_at, p_backlog, n,
               extract(epoch from clock_timestamp() - t0) * 1000,
               'exact count timed out; planner estimate', true)
  on conflict (sampled_at, backlog) do update
     set depth = excluded.depth, duration_ms = excluded.duration_ms,
         error = excluded.error, estimated = true;

  return n;
end $$;

revoke all on function market.sample_backlog_estimate(text, timestamptz) from public;
grant execute on function market.sample_backlog_estimate(text, timestamptz) to service_role;

notify pgrst, 'reload schema';
