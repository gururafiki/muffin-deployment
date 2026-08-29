-- Sample the numbers that gate the segment feature — IDEMPOTENT.
--
-- A NUMBER NOBODY SAMPLES CANNOT BE TRENDED, AND THE ONE THAT MATTERED WAS NOT SAMPLED. Every
-- segment gauge on the dashboard was a fact count — `security_segment` rows, filings parsed,
-- facts written per run — and all of them rose steadily while the feature did not work, because
-- the backlog was ordered by a property of the COMPANY and walked one filer's entire history
-- before starting the next. 440 filings, fourteen securities, ~3,500 filers. `written` read as
-- throughput and `remaining` fell.
--
-- `segments.companies` is the number that would have shown it in a day, so it is sampled beside
-- `segments.filings_parsed`: the two DIVERGING is the healthy shape, and them climbing together
-- at ~30 filings per company is the defect returning.
--
-- `segments.comparable_concepts` is the feature's own definition of done — concepts on which TWO
-- OR MORE companies can actually be compared. It read **1** on 2026-08-29, against 12 concepts
-- with a single company and 11 seeded and never matched. An aggregate that cannot fall below one
-- company is not a comparison.
--
-- `create or replace function` PRESERVES THE EXISTING ACL, so this is drop-then-create and the
-- grant below is load-bearing rather than decorative.
drop function if exists market.sample_universe();
create function market.sample_universe()
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
  newest timestamptz;
begin
  perform set_config('statement_timeout', '30s', true);

  -- ESTIMATED rows, exact on-disk size. `reltuples` is -1 for a relation never analysed
  -- (Postgres 14+ distinguishes that from a genuine zero), so it is skipped rather than recorded
  -- as -1. Exact counting all 63 tables was 10,252 ms cold and bought nothing a gauge needs.
  for r in
    select c.relname as tbl, c.reltuples as est, pg_total_relation_size(c.oid) as bytes
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'market' and c.relkind = 'r'
     order by c.relname
  loop
    if r.est >= 0 then
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, 'rows_estimate.' || r.tbl, r.est) on conflict do nothing;
      taken := taken + 1;
    end if;
    insert into market.universe_sample (sampled_at, metric, value)
         values (ts, 'bytes.' || r.tbl, r.bytes) on conflict do nothing;
    taken := taken + 1;
  end loop;

  -- Negative-cache populations. EXACT, and they have to be: a 20% jump is an alert, and an
  -- estimate's error bar is wider than that.
  for r in
    select c.relname as tbl, a.attname as col
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid
     where ns.nspname = 'market' and c.relkind = 'r'
       and a.attnum > 0 and not a.attisdropped and a.attname like '%\_missing\_at'
     order by c.relname, a.attname
  loop
    begin
      execute format('select count(*) from market.%I where %I is not null', r.tbl, r.col) into n;
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, format('missing.%s.%s', r.tbl, r.col), n) on conflict do nothing;

      -- ABOUT TO LAPSE. The negative caches expire at 30 days, so a mark older than 23 days is
      -- work returning to a backlog within the week. Without this the backlog simply jumps and
      -- nothing explains it.
      execute format(
        'select count(*) from market.%I where %I is not null and %I < now() - interval ''23 days''',
        r.tbl, r.col, r.col) into n;
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, format('expiring.%s.%s', r.tbl, r.col), n) on conflict do nothing;
      taken := taken + 2;
    exception when others then null;
    end;
  end loop;

  -- FRESHNESS. The age in hours of the newest row per timestamped table, discovered rather than
  -- listed — 449 ms for all of them, slowest 141 ms. An AGE rather than a timestamp so a panel
  -- can threshold it without knowing when it was sampled.
  for r in
    select c.relname as tbl, a.attname as col
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid
     where ns.nspname = 'market' and c.relkind = 'r'
       and a.attnum > 0 and not a.attisdropped and a.attname in ('as_of', 'fetched_at')
     order by c.relname, a.attname
  loop
    begin
      execute format('select max(%I) from market.%I', r.col, r.tbl) into newest;
      if newest is not null then
        insert into market.universe_sample (sampled_at, metric, value)
             values (ts, format('fresh_hours.%s.%s', r.tbl, r.col),
                     extract(epoch from (ts - newest)) / 3600.0) on conflict do nothing;
        taken := taken + 1;
      end if;
    exception when others then null;
    end;
  end loop;

  -- The newest price bar. Its own entry because `security_price` keys on `date`, not `as_of`, and
  -- because it is the single most load-bearing freshness number here. Cheap only since migration
  -- 130 indexed (date, security_id): this was 9,366 ms before it and is 0.475 ms after.
  begin
    select max(date)::timestamptz into newest from market.security_price;
    if newest is not null then
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, 'fresh_hours.security_price.date',
                   extract(epoch from (ts - newest)) / 3600.0) on conflict do nothing;
      taken := taken + 1;
    end if;
  exception when others then null;
  end;

  -- STALENESS AS THE APP SEES IT. `performance.stale_after` is the pipeline's own judgement about
  -- when a number stops being good; this is how much of it has passed that point. 76,209 today.
  begin
    select count(*) into n from market.performance where stale_after < now();
    insert into market.universe_sample (sampled_at, metric, value)
         values (ts, 'stale.performance', n) on conflict do nothing;
    taken := taken + 1;
  exception when others then null;
  end;

  -- GROWTH. Whether the universe is still being extended — i.e. whether `promote-wave` and the
  -- fund ingest are doing anything. A flat line here with a healthy backlog means promotion has
  -- stopped, which nothing else reports.
  begin
    select count(*) into n from market.security where first_seen_at > now() - interval '7 days';
    insert into market.universe_sample (sampled_at, metric, value)
         values (ts, 'growth.securities_7d', n) on conflict do nothing;
    select count(*) into n from market.security where first_seen_at > now() - interval '30 days';
    insert into market.universe_sample (sampled_at, metric, value)
         values (ts, 'growth.securities_30d', n) on conflict do nothing;
    taken := taken + 2;
  exception when others then null;
  end;

  -- THE SCHEDULER ITSELF. With GitHub Actions gone, pg_cron is the only thing driving the
  -- pipeline and its failure is silent — the data just stops. `minutes_since_tick` is what the
  -- "scheduler has gone silent" alert watches; the rotation fires every 5 minutes, so anything
  -- past 30 means it has stopped.
  begin
    insert into market.universe_sample (sampled_at, metric, value)
    select ts, m, v from (
      select 'scheduler.ticks_1h' as m, ticks_1h::numeric as v from market.scheduler_health()
      union all select 'scheduler.failed_1h', failed_1h from market.scheduler_health()
      union all select 'scheduler.minutes_since_tick', minutes_since_tick from market.scheduler_health()
    ) s where v is not null
    on conflict do nothing;
    taken := taken + 3;
  exception when others then null;   -- no pg_cron in the test image
  end;

  -- EXACT, because market-verify.yml asserts floors on exactly these.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, m, v from (
    select 'equities' as m, count(*)::numeric as v from market.security where security_type_code = 'equity'
    union all select 'identifiers.isin',   count(*) from market.security_identifier where kind_code = 'isin'
    union all select 'identifiers.ticker', count(*) from market.security_identifier where kind_code = 'ticker'
    union all select 'identifiers.cusip',  count(*) from market.security_identifier where kind_code = 'cusip'
    union all select 'tracked_funds.enabled',  count(*) from market.tracked_fund where enabled = true
    union all select 'tracked_funds.ingested', count(*) from market.tracked_fund where last_report_date is not null
  ) s
  on conflict do nothing;

  -- BREADTH, WHICH IS THE NUMBER THAT GATES THE SEGMENT FEATURE. Companies REACHED, not facts
  -- written: while `pending_segments` was ordered by fund weight the queue walked one company's
  -- whole 20-year history before starting the next, so 440 parsed filings belonged to fourteen
  -- securities — and every other signal (`written`, `remaining`, `ok`, the reconciliation guard)
  -- said healthy, because the rows being written were correct. They were the wrong rows first.
  -- Nothing here could see it, because nothing counted companies.
  --
  -- `count(distinct security_id)` over `security_segment` measured 486 ms at 1.92M rows, which is
  -- affordable twice an hour. It is EXACT rather than a `reltuples` estimate because the whole
  -- point is a small integer (14 against 3,500) where a few percent of error is the entire signal.
  begin
    insert into market.universe_sample (sampled_at, metric, value)
    select ts, m, v from (
      select 'segments.companies' as m, count(distinct security_id)::numeric as v
        from market.security_segment
      union all
      select 'segments.filings_parsed', count(*)
        from market.security_filing where segments_parsed_at is not null
      union all
      select 'segments.comparable_concepts', count(*) from (
        select 1 from market.security_segment_spine
         where concept_code is not null
         group by concept_code having count(distinct security_id) >= 2) c
    ) s
    on conflict do nothing;
    taken := taken + 3;
  exception when others then null;   -- the spine may not exist yet on a partially-applied database
  end;

  return taken + 6;
end $$;

revoke execute on function market.sample_universe() from public;
grant execute on function market.sample_universe() to service_role;

notify pgrst, 'reload schema';
