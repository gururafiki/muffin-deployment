-- FRESHNESS, STALENESS, AND THE WORK ABOUT TO COME BACK.
--
-- `sample_universe` records how much data there is. It says nothing about how OLD it is, how much
-- of it the app already considers stale, whether the universe is still growing, or how much
-- negative-cached work is about to lapse back into the backlogs.
--
-- Every addition below was timed on the node 2026-08-27 before being written:
--
--     max() over every as_of / fetched_at column     449 ms   (slowest single: 141 ms)
--     performance rows past stale_after               11 ms   (76,209 rows today)
--     securities created per day                      29 ms
--     negative-cache marks near their lapse            2 ms
--
-- ── WHY `expiring.*` IS WORTH A METRIC ────────────────────────────────────────────────────────
--
-- A `%_missing_at` mark means "we asked and the provider had nothing", and it lapses after 30
-- days so a security can be re-tried. That lapse is INVISIBLE today: one morning a backlog is
-- 300 deep and the next it is 3,000, with nothing to say why. This counts the marks within seven
-- days of lapsing, which is the work about to reappear. Negative caches have gone wrong in this
-- pipeline five separate times; knowing what is about to come back is worth 2 ms.

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

  return taken + 6;
end $$;

notify pgrst, 'reload schema';
