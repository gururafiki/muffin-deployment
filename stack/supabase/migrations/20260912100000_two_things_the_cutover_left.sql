-- Two things the D2 cutover left behind, both found by verifying it rather than by a failure.

-- ── 1. THE DAILY SERIES LOST ITS WINDOW, AND THE APP PAGES THROUGH THE DIFFERENCE ─────────────
--
-- `price_series`' daily arm moved from `security_price` — which the old resource only ever filled
-- with a rolling ~400-day window — onto `price_bar`, which holds everything back to 1980. Measured
-- on AAPL the morning after the cutover: **275 rows -> 11,528**, median 273 across every security.
-- The app pages at 1000 and stops on a short page, so nothing is truncated and nothing is wrong;
-- it simply makes **twelve sequential round trips to draw at most 365 days**, because the longest
-- daily range the chart offers is 1Y.
--
-- Bounded on the clock rather than per security, deliberately. A per-security anchor is the more
-- correct shape and costs either a `group by` over 58 M rows on every chart load or a new
-- `price_history_to` column to mirror `price_history_from`; measured, the difference it buys is
-- **13 securities of 11,716** whose last bar predates the window — delisted names, which keep
-- their WEEKLY series, since that arm stays unbounded and is what a 3Y/5Y chart will read.
--
-- 400 days, not 365: the range is calendar days and the bars are trading days, so a year needs
-- slack or the 1Y chart is short by every weekend and holiday in it.
create or replace view market.price_series as
select ss.symbol, pb.trade_date as date, pb.close, 'daily'::text as grain
  from market.price_bar pb
  join market.symbol_security ss on ss.security_id = pb.security_id
 where pb.trade_date > current_date - 400
union all
select symbol, date, close, 'weekly'::text as grain
  from (
    select distinct on (ss.symbol, date_trunc('week', pb.trade_date))
           ss.symbol, pb.trade_date as date, pb.close
      from market.price_bar pb
      join market.symbol_security ss on ss.security_id = pb.security_id
     order by ss.symbol, date_trunc('week', pb.trade_date), pb.trade_date desc
  ) w;

-- ── 2. `scheduled` TESTS THAT A ROW EXISTS, NOT THAT IT IS ENABLED ────────────────────────────
--
-- The stalled-resource alert exempts a retired resource via `resource_health.scheduled`, and its
-- own comment explains why: "a retired resource keeps its history for the 30 days
-- `resource_health` looks back over, so it goes on looking stalled long after it was correctly
-- switched off." That exemption was written for `security-eps-history`, which migration 138
-- REMOVED from the cron — the row was deleted, so `exists` went false and the rule stayed quiet.
--
-- The D2 cutover retires its ten resources by setting `enabled = false` and KEEPING the row, on
-- purpose: a retirement should be re-assertable on every deploy, and rollback is then one update
-- rather than ten re-inserts. So `exists` stays true, `last_worked` freezes at the cutover, and
-- `greatest(12, ttl_hours * 2.5)` would have fired the alert on all ten within twelve hours —
-- ten false positives, on the day the thing they describe was done deliberately.
--
-- A gate that is red for a reason nobody will act on is how the next true positive gets missed;
-- this schema has already paid for that twice. `check_resource_health.py` reads the same column
-- and already exempts `scheduled = false`, so it inherits the fix rather than needing its own.
create or replace view market.resource_health as
select resource,
    min(started_at) as first_seen,
    max(finished_at) filter (where ok and not skipped) as last_worked,
    max(finished_at) filter (where ok) as last_ok_including_skips,
    count(*) filter (where skipped and started_at > (now() - '06:00:00'::interval)) as skips_6h,
    count(*) filter (where started_at > (now() - '06:00:00'::interval)) as runs_6h,
    ( select extract(epoch from l.min_interval) / 3600.0
        from market.refresh_log l where l.resource = r.resource) as ttl_hours,
    (exists ( select 1 from market.cron_resource cr
               where cr.resource = r.resource and cr.enabled)) as scheduled
   from market.refresh_run r
  where started_at > (now() - '30 days'::interval)
  group by resource;
