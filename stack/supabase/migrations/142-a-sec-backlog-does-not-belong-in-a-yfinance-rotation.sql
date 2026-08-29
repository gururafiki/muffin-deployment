-- `security-segments` GETS ITS OWN SCHEDULE, FOR THE REASON MIGRATION 137 ESTABLISHED.
--
-- `market.cron_tick()` posts one resource every five minutes, and that pacing exists for exactly
-- one reason: seventeen resources fired back to back is what tripped **yfinance's** rate limit on
-- 2026-08-13 and negative-cached ~8,300 securities as permanently unanswerable. It is a budget for
-- one provider, and 137 moved the four resources that spend none of it onto their own jobs.
--
-- This resource spends SEC's budget instead — documented at 10 requests/second, uncontended, and
-- shared only with `security-xbrl` and `sec-cik-map`. Two facts make the rotation the wrong home:
--
--   * IT WOULD BE FAR TOO SLOW. A 38-resource rotation gives each member a turn every ~190
--     minutes, i.e. ~7.5 runs a day. At 20 filings a run that is 150 filings a day against a
--     backlog of **30,072** 10-K/10-Q/20-F filings already in `security_filing` — about 200 days,
--     during which the feature shows almost nothing. On its own five-minute schedule it is ~5,700
--     filings a day and the backfill lands in under a week.
--   * IT WOULD SLOW THE ROTATION DOWN for every yfinance backlog, to pay for work that is not
--     competing with them for anything.
--
-- The cost is ~0.7 requests/second against SEC, which is 7% of the documented allowance, and the
-- offset minute keeps it out of the same second as the rotation on a single Always-Free node.

-- REGISTERED BUT NOT IN THE ROTATION. `cron_next()` counts only enabled resources, so this is what
-- takes it out of the five-minute sweep — while keeping the row, which is what `logic-check.ts`'s
-- "every backlog resource is actually SCHEDULED" guard reads. Deleting the row instead would make
-- that guard report the resource as unscheduled while it is, in fact, running more often than
-- anything else. (`exchange-listings` sat deployed, reachable and unscheduled for weeks because
-- nothing checked this direction; the guard exists because of it.)
insert into market.cron_resource (position, resource) values
  (380, 'security-segments'),
  (390, 'security-filing-history')
on conflict (position) do update set resource = excluded.resource;

update market.cron_resource set enabled = false
 where resource in ('security-segments', 'security-filing-history');

do $$ begin
  -- :02, :07, :12 … deliberately offset from the rotation's `*/5` so the two never fire in the
  -- same minute. Same reasoning as 137's staggered offsets: four simultaneous passes on one
  -- Always-Free node is a self-inflicted load spike.
  perform cron.schedule('muffin-segments', '2-59/5 * * * *',
    $c$ select market.cron_post('security-segments') $c$);
  -- Quarter-hourly, offset again. This one walks a filer's WHOLE history in a single request and
  -- then leaves it alone for 30 days, so it has no backlog to race — at 8 filers a run it covers
  -- the 3,518 securities with a CIK in about five days and then does almost nothing.
  perform cron.schedule('muffin-filing-history', '9-59/15 * * * *',
    $c$ select market.cron_post('security-filing-history') $c$);
exception when others then
  -- No pg_cron in the migration-test image. The cron_resource rows above still apply, which is the
  -- part with logic worth testing.
  raise notice '  --  could not schedule pg_cron job (%): it will be scheduled on the next apply', sqlerrm;
end $$;
