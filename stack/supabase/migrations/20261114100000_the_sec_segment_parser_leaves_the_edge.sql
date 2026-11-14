-- THE SEC SEGMENT PARSER LEAVES THE EDGE (Phase 6 step 3, decided by the user 2026-11-09).
--
-- muffin-ingest's `sec_segments` job (`raw_sec_instance` -> `sec_segment`) now reads each SEC
-- accounts filing's XBRL instance and writes `market.security_segment` under the same
-- `sec-segments` source, with the same parser (a line-for-line port of `segments.ts`, 9,800 of
-- 9,800 stored rows reproduced). Decision 3 is that two writers never run at once, so the edge's
-- resource retires before the Dagster sensor starts.
--
-- Why it had to move: `security-segments` failed 343 of its 2,015 runs in the week to 2026-11-09,
-- on `pending_segments`, a view that ranks every filing of every filer and times out at the
-- PostgREST role's 8 s once Phase 5's grid took `security_filing` to 1.2 M rows. The Dagster lane
-- asks the same question per filer through the primary key.
--
-- RETIRES: security-segments
--
-- The name is in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate. Its rotation
-- row was already disabled when it moved to its own job (legacy 142); the job is removed here. The
-- handler, `segments.ts` and `pending_segments` stay until step 8 deletes them after three clean
-- days, so rolling back is re-scheduling one job and removing one map entry.

update market.cron_resource set enabled = false where resource = 'security-segments';

do $$
begin
  -- Guarded on the table, not with an exception handler: the migration tests run on plain
  -- Postgres with no pg_cron, where even planning a query that names `cron.job` fails.
  if to_regclass('cron.job') is not null then
    execute $q$select cron.unschedule(jobname) from cron.job where jobname = 'muffin-segments'$q$;
  end if;
end $$;
