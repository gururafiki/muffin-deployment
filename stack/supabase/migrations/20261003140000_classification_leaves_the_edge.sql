-- CLASSIFICATION LEAVES THE EDGE (Phase 3 stage 5, contract).
--
-- `derive-classifications` failed every daily run from 2026-09-27: PostgREST's role stops a
-- statement at 8 s, and `derive_segment_classification` measured 20.1 s on 2026-10-03. The Dagster
-- asset `security_classification` (muffin-ingest#91) makes the same three calls as `ingest_rw`,
-- with a 120 s timeout, on a new fund holding or daily at 05:44 UTC, the slot this job held.
-- EXECUTE for `ingest_rw` landed first, in 20261003130000.
--
-- RETIRES: derive-classifications
--
-- The same name is in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate and names
-- the asset; `logic-check.ts` holds the two lists equal. The handler stays until this has run clean
-- for three days, so the rollback is deleting the map entry and re-scheduling the job.

update market.cron_resource set enabled = false where resource = 'derive-classifications';

-- The resource ran from its own job (legacy migration 137), so disabling the rotation row stopped
-- nothing. Guarded on the relation, as in 20260926130000: the migration tests have no pg_cron.
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice '  --  no pg_cron here (the migration tests): nothing to unschedule';
    return;
  end if;
  execute $q$ select cron.unschedule(jobid) from cron.job where jobname = 'muffin-classify' $q$;
end $$;
