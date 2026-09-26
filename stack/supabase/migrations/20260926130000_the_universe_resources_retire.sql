-- THE UNIVERSE FAMILY'S EDGE RESOURCES RETIRE.
--
-- Phase 3 moved the universe onto Dagster: N-PORT discovery and the OpenFIGI venue sweep went live
-- on 2026-09-21, the symbology ladder on 09-24, the CIK and NSE registries on 09-21. The edge
-- resources they replaced kept running beside them. Measured from `refresh_run` over the seven
-- days to 2026-09-26:
--
--   * `exchange-listings` ran 68 times and wrote 112,451 rows into `market.exchange_listing`, which
--     has had no reader since `untracked_listing` moved to `venue_listing` — spending the same
--     OpenFIGI `/v3/filter` allowance the Dagster sweep needs.
--   * `security-local-symbols` failed all 68 of its runs, on `(provider_code, symbol)`: the
--     one-listing-one-security key the Dagster ladder handles by refusing, not by crashing.
--   * `security-tickers`, `security-yahoo-symbols` and `security-symbol-repair` ran 67-68 times each
--     and wrote nothing; `fund-holdings`, `sec-cik-map` and `in-symbols` skipped every run on
--     their TTLs; `promote-wave` ran 14 times from its own job and promoted nothing.
--   * `promote-listing` has no recorded run since run history began (2026-08-27). The Track button
--     calls `market.promote_listing` directly.

-- The parity gate for `fund-holdings` shipped first (muffin-ingest#81): the Dagster lane now writes
-- the bond debt terms and learns the lookup codes it used to be the only writer of.
--
-- RETIRES: fund-holdings, exchange-listings, security-tickers, security-local-symbols
-- RETIRES: security-yahoo-symbols, security-symbol-repair, promote-wave, promote-listing
-- RETIRES: sec-cik-map, in-symbols
--
-- The same ten names are in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate;
-- `logic-check.ts` holds the two lists equal. Unconditional, like D2's: a re-enabled row is drift
-- to be corrected on the next deploy, not a choice to be preserved.

update market.cron_resource set enabled = false
 where resource in ('fund-holdings','exchange-listings','security-tickers','security-local-symbols',
                    'security-yahoo-symbols','security-symbol-repair','promote-wave',
                    'sec-cik-map','in-symbols');

-- `promote-wave` ran from its own job, not the rotation, so disabling its row stopped nothing.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'muffin-promote') then
    perform cron.unschedule('muffin-promote');
  end if;
end $$;

-- "FUNDS INGESTED" IS DERIVED, NOT A CURSOR. Two readers — `sample_universe`'s
-- `tracked_funds.ingested` and market-verify's "funds ingested" floor — counted
-- `tracked_fund.last_report_date`, a column only the retired resource wrote. Left alone they would
-- freeze, and a fund added later would never count as ingested. The newest report is already a fact
-- in `fund_holding`, so it is read from there.
create or replace view market.tracked_fund_latest as
select tf.symbol,
       i.security_id as fund_id,
       max(h.as_of) as last_report_date
  from market.tracked_fund tf
  left join market.security_identifier i
    on i.kind_code = 'ticker' and i.value = tf.symbol
  left join market.fund_holding h
    on h.fund_id = i.security_id
 group by tf.symbol, i.security_id;

grant select on market.tracked_fund_latest to anon, authenticated, service_role;

-- `sample_universe`, unchanged but for `tracked_funds.ingested`, which now reads the view above.
CREATE OR REPLACE FUNCTION market.sample_universe()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
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

  -- The newest price bar, the single most load-bearing freshness number here. From `price_bar`
  -- since 2026-09-26: `security_price` was retired on 09-12 and this kept reading it for two
  -- weeks, reporting its frozen 09-11 bar as the newest price in the universe. No index leads on
  -- `trade_date`, so the window is what keeps it cheap: it prunes to the current partition.
  begin
    select max(trade_date)::timestamptz into newest from market.price_bar
     where trade_date > current_date - 30;
    if newest is not null then
      insert into market.universe_sample (sampled_at, metric, value)
           values (ts, 'fresh_hours.price_bar.trade_date',
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
    union all select 'tracked_funds.ingested', count(*) from market.tracked_fund_latest where last_report_date is not null
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
end $function$;
