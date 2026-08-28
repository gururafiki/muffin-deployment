-- A PROVIDER-PACED ROTATION SHOULD ONLY CARRY PROVIDER WORK.
--
-- `market.cron_tick()` posts one resource every five minutes, and the pacing exists for exactly
-- one reason: seventeen resources fired back to back is what tripped yfinance's rate limit on
-- 2026-08-13 and negative-cached ~8,300 securities as permanently unanswerable. That constraint is
-- about REQUESTS TO EXTERNAL PROVIDERS.
--
-- Four of the rotation's slots make no external request at all:
--
--     facets-refresh          pure SQL — refreshes security_facets and symbol_security
--     security-metrics        pure SQL — derive_security_metrics + derive_ttm
--     promote-wave            pure SQL — promotes listings already held
--     derive-classifications  pure SQL — sector membership from fund holdings
--
-- They are being rate-limited against a budget they do not spend, and one of them matters:
-- `facets-refresh` declares a 60-minute TTL and a 38-resource rotation gives it a turn every ~190
-- minutes, so the MATERIALISED spine every filtered list and every symbol lookup reads is up to
-- 3.2x staler than intended. `derive-classifications` is the opposite waste — a 30-day TTL means
-- it self-skips ~227 turns out of every 228, occupying a slot to do nothing.
--
-- This is the same argument that already keeps `observability-sample` out of the rotation: it
-- touches no provider, so it is free to run often, and its rate is what decides whether a dashboard
-- draws a line or a dot.
--
-- ── WHAT CHANGES ──────────────────────────────────────────────────────────────────────────────
--
-- The four move to their own pg_cron jobs at cadences matching what they actually declare, and the
-- rotation shrinks to the resources that spend provider budget — which also tightens the sweep for
-- the ones that do.
--
-- `enabled = false` rather than deleting the rows: `cron_next()` counts only enabled resources, so
-- this removes them from the rotation while keeping them registered, which is what
-- `logic-check.ts`'s "every backlog resource is actually SCHEDULED" guard reads. Deleting them
-- would make that guard fail for resources that are, in fact, scheduled — more often.
update market.cron_resource set enabled = false
 where resource in ('facets-refresh', 'security-metrics', 'promote-wave', 'derive-classifications');

-- Their own schedules. Offsets are staggered so they never fire in the same minute as each other
-- or as the hourly observability sample (:04) — four simultaneous SQL passes on a single
-- Always-Free node is a self-inflicted load spike.
do $$ begin
  -- Hourly, which is what its TTL asks for. This is the one with a user-visible cost.
  perform cron.schedule('muffin-facets',        '14 * * * *', $c$ select market.cron_post('facets-refresh') $c$);
  -- Every 30 minutes: pure SQL, and `pending_metrics` is a DRIFT COUNTER rather than a queue, so
  -- running it often is how drift stays small rather than how work gets done.
  perform cron.schedule('muffin-metrics',       '24,54 * * * *', $c$ select market.cron_post('security-metrics') $c$);
  -- Twice a day. Promotion is opt-in per venue and does nothing at all until an operator enables
  -- one, so a high cadence would be pure noise.
  perform cron.schedule('muffin-promote',       '34 */12 * * *', $c$ select market.cron_post('promote-wave') $c$);
  -- Daily. Its own TTL is 30 days; this simply means a fund ingested today is classified today
  -- rather than whenever the rotation next reaches it.
  perform cron.schedule('muffin-classify',      '44 5 * * *', $c$ select market.cron_post('derive-classifications') $c$);
exception when others then
  -- No pg_cron in the migration-test image. The rotation table changes above still apply, which is
  -- the part with logic worth testing.
  raise notice '  --  could not schedule pg_cron jobs (%): they will be scheduled on the next apply', sqlerrm;
end $$;

-- ── THE ETF COMPLETENESS SEED WAS ASKING FOR SOMETHING THIS PIPELINE CANNOT PRODUCE ───────────
--
-- All 74 ETFs read 0% complete, and the SEED is what is wrong, not the data. `required_facet`
-- demands `price` of an ETF, but `pending_prices` is scoped `where security_type_code = 'equity'`,
-- so an ETF can never receive a row in `security_price` — ETF returns come from `performance`,
-- computed off `etf/historical`, and the bars were never stored. A completeness metric that
-- reports a permanent 0% for a whole security type is a number people learn to ignore, which
-- is the failure mode `required_facet` exists to prevent (a bond owes what a bond can have).
--
-- A DELETE rather than an edited seed: the insert is `on conflict do nothing` precisely so Studio
-- edits survive a redeploy, which also means removing a line from it changes nothing on an
-- existing database. Wrapped in `one_shot` so a deliberate re-add in Studio is not undone on the
-- next deploy — the same reason every data repair here is one-shot.
do $$
declare removed bigint;
begin
  if exists (select 1 from market.one_shot where key = '137-etf-does-not-owe-a-price-row') then
    raise notice '  --  137: ETF facet already corrected, skipping';
  else
    delete from market.required_facet where security_type_code = 'etf' and facet = 'price';
    get diagnostics removed = row_count;
    raise notice '  --  137: removed % ETF price requirement(s)', removed;
    insert into market.one_shot (key, reason) values
      ('137-etf-does-not-owe-a-price-row',
       'pending_prices is equity-scoped, so an ETF can never have a security_price row. Requiring it reported all 74 ETFs as 0% complete for ever.');
  end if;
end $$;

notify pgrst, 'reload schema';
