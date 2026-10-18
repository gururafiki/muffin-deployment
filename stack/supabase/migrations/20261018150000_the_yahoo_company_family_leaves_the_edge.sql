-- THE YAHOO COMPANY FAMILY LEAVES THE EDGE (Phase 4 step 9).
--
-- The Dagster company lane (`yahoo_companies`, muffin-ingest#110 and #113) went live 2026-10-17
-- 20:27 UTC, and its first scheduled day (2026-10-18) visited 1,762 companies with every counter
-- summing and nothing throttled. The edge resources it replaces kept running beside it. Measured
-- from `refresh_run` over the 24 hours to 2026-10-18 14:30 UTC:
--
--   * `security-dividends` wrote 11,201 rows into `market.security_corporate_action`, beside the price
--     lane's chart-events writer (`yahoo_corporate_action`, 71,252 rows on its first night): the same
--     source and the same keys, so two writers;
--   * `security-quarters` wrote 275 quarterly statements beside the company lane's statement writer;
--   * `security-metrics`, from its own job `muffin-metrics` at :24 and :54, wrote 209,100 metric rows
--     beside Dagster's `derived_security_metrics` at :17 and :47, which runs the same two functions
--     under `ingest_rw`'s 120 s timeout instead of PostgREST's 8 s;
--   * `security-profiles`, `-profile-detail`, `-industries`, `-fundamentals`, `-share-stats`,
--     `-management` and `instrument-profile` ran 13-14 times each and wrote nothing: drained
--     fetch-once backlogs, or a weekly refresh the lane now does for every company.
--
-- `instrument-profile` retires because all 35 curated equities resolve to a security the company
-- lane visits; its other 13 rows (bonds, cash, crypto, funds) were never its to fetch.
--
-- RETIRES: security-profiles, security-profile-detail, security-industries, security-fundamentals
-- RETIRES: security-share-stats, security-management, security-quarters, security-dividends
-- RETIRES: instrument-profile, security-metrics
--
-- NOT HERE:
--   * `security-corporate-actions` (Tiingo) waits for its parity check. On 2026-10-18 only 13 of its
--     6,819 dividend rows had a Yahoo row to compare with, because the chart-events lane started that
--     night; its first price rotation covers Tiingo's 369 securities by about 10-22.
--   * `security-statements` keeps its SEC half; its Yahoo half goes in a change of its own, because
--     three tests assert that half's backlog semantics.
--   * `security-refresh` is not retired: `index.ts` turns it into a launcher for the company lane.
--
-- The names are in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate;
-- `logic-check.ts` holds the two lists equal. The handlers stay until three clean days (step 10), so
-- the rollback is deleting the map entries, re-enabling the rows and re-scheduling the job:
-- `select cron.schedule('muffin-metrics', '24,54 * * * *', $$select market.cron_post('security-metrics')$$)`.

update market.cron_resource set enabled = false
 where resource in ('security-profiles','security-profile-detail','security-industries',
                    'security-fundamentals','security-share-stats','security-management',
                    'security-quarters','security-dividends','instrument-profile',
                    'security-metrics');

-- `security-metrics` ran from its own job, so disabling its row (it already was) stopped nothing.
-- Guarded on the relation, as in 20260926130000: the migration tests have no pg_cron.
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice '  --  no pg_cron here (the migration tests): nothing to unschedule';
    return;
  end if;
  execute $q$ select cron.unschedule(jobid) from cron.job where jobname = 'muffin-metrics' $q$;
end $$;
