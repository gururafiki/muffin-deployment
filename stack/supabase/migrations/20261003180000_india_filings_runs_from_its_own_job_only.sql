-- `in-filings` RUNS FROM ITS OWN pg_cron JOB ONLY.
--
-- It has its own job, `muffin-in-filings` (every 15 minutes from :13), and still had an ENABLED
-- rotation row, so it was scheduled twice. The rotation slot arrives to find the resource's TTL
-- fresh and returns `{"skipped": true, "reason": "fresh or in flight"}`, recorded `ok`: measured
-- 2026-10-03 14:20, between the job's 14:13 and 14:28 runs. Every resource moved onto its own job
-- has had its row disabled; this one was missed, the same miss as `security-in-segments`.
--
-- `resource_health.scheduled` still counts it: since 20261003120000 a resource fired by its own
-- active job is scheduled whether or not its rotation row is enabled.

update market.cron_resource set enabled = false where resource = 'in-filings' and enabled;
