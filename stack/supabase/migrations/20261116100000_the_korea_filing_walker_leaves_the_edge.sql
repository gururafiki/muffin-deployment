-- THE KOREA FILING WALKER LEAVES THE EDGE (Phase 6 step 5, decided by the user 2026-11-09).
--
-- muffin-ingest's `dart_segments` job (`raw_dart_filings` -> `dart_segment`) now lists each DART
-- filer's periodic disclosures, files its annual reports in `market.security_filing` and reads each
-- one's XBRL archive into `market.security_segment` under the same `dart` source, and
-- `raw_dart_corp_codes` -> `security_dart_filer` maps Korean equities to DART corp codes from
-- DART's own registry. Decision 3 is that two writers never run at once, so the edge's walker
-- retires before the Dagster schedules start. Its parser retired on 2026-11-04 (migration
-- 20261104110000), waiting for this lane.
--
-- RETIRES: kr-filings
--
-- PORTED AS-IS (decision 2), SO NOTHING IS READ AGAIN. Golden parity on 2026-11-16 re-read 768 of
-- the 769 filings the edge parsed: 21,515 of 21,519 comparable rows match, and the other 20 are two
-- Hyundai Motor filings the edge read hours before migration 196 added `long_lived_assets` without
-- a parser bump. The edge's own parser, run on those two instances with today's vocabulary, agrees
-- with the port on every fact. Those two are re-read by name in the lane's first live run.
--
-- The name is in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate. The handler
-- and `dart.ts` stay until the lane has run clean for three days (step 8); the backlog views
-- (`pending_kr_history`, `pending_kr_segments`) and `dart_discovery_cursor` go at the contract
-- (step 9).

update market.cron_resource set enabled = false where resource = 'kr-filings';

do $$
begin
  -- Guarded on the table, not with an exception handler: the migration tests run on plain
  -- Postgres with no pg_cron, where even planning a query that names `cron.job` fails.
  if to_regclass('cron.job') is not null then
    execute $q$select cron.unschedule(jobname) from cron.job where jobname = 'muffin-kr-filings'$q$;
  end if;
end $$;
