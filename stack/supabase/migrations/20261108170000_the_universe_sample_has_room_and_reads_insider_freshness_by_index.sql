-- THE UNIVERSE SAMPLE HAS ROOM, AND READS `insider_trade`'s FRESHNESS FROM AN INDEX.
--
-- WHY. `muffin-universe` runs `set statement_timeout = '60s'; select market.sample_universe()`
-- hourly (20261003135000). Its durations, from `cron.job_run_details`: 21-46 s on 11-04/05, 50-58 s
-- from 11-07 20:05, and 13 of the 23 runs from 11-07 11:05 to 11-08 15:05 cancelled at 60 s. With no
-- universe sample for three hours, "The scheduler has stopped firing" reads 9999 and fires, while
-- `muffin-rotation` runs every five minutes. It fired from 11-08 ~14:05.
--
-- Timed part by part on production, 2026-11-08 16:10 UTC, nothing else running: 43.5 s of the ~52 s
-- is the freshness loop (`select max(as_of|fetched_at)` per timestamped table), and **33.4 s of that
-- is `max(as_of)` over `insider_trade`**: a sequential scan of 5.52 M rows (3.2 GB), because no index
-- leads on `as_of`. The insider history took the table from 0.75 M rows on 11-07, which is the jump.
-- Next: `price_bar`'s newest trade date 4.7 s, `security_metric`'s `max(fetched_at)` and `max(as_of)`
-- 3.3 s each; the negative-cache counts 0.2 s in all.
--
-- WHAT.
--   1. An index on `insider_trade (as_of)`. Built on production in a rolled-back transaction: 43 s
--      under a SHARE lock (it blocks writes to the table, not reads; the Form 4 lane writes from 11:00
--      UTC on weekdays and the data-set lane on Mondays), 38 MB, and `max(as_of)` then 0.06 ms by an
--      index-only backward scan.
--   2. `muffin-universe` gets 300 s, as `muffin-coverage` did this morning (20261108130000) and
--      `muffin-segment-spine` before it. The sample is observability, read by Grafana and the alerts,
--      never by the app. With the index it should take ~20 s again; the bound is headroom, so the
--      next table to grow does not take the scheduler alert with it.
--
-- NOT DONE. `security_metric` (7.9 M rows) and `price_bar` are left on their scans: ~11 s together,
-- and an index on a table the derivation rewrites costs every write. If they grow toward the bound,
-- the freshness numbers should come from a cheaper source rather than more indexes.
--
-- Guard: stack/supabase/tests/the-universe-sample-reads-freshness-by-index.sql. Guarded on the
-- relation for pg_cron: the migration tests run on plain Postgres with no pg_cron.

create index if not exists insider_trade_as_of_idx on market.insider_trade (as_of);

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice '  --  no pg_cron here (the migration tests): nothing to schedule';
    return;
  end if;
  execute $q$
    select cron.schedule(
      'muffin-universe',
      '5 * * * *',
      $c$set statement_timeout = '300s'; select market.sample_universe()$c$)
  $q$;
end $$;
