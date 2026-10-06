-- THE TWELVE pg_cron JOBS THE LEGACY MIGRATIONS SCHEDULED, DECLARED WHERE A REBUILD CAN SEE THEM.
--
-- WHY. A pg_cron job is a row in `cron.job`, and the baseline is a dump of three schemas — `market`,
-- `api` and `ingest` — so it carries none of them. Production has all twelve because the legacy
-- migrations scheduled them before the 2026-09-10 cutover. A database built from the repo had only
-- the four scheduled since (`muffin-universe`, `muffin-quality`, `muffin-coverage`,
-- `muffin-segment-spine`): nothing would rotate the edge resources, refresh the facets, prune
-- pg_cron's own run log or sample the backlogs, and nothing would say so.
--
-- WHAT. Each job exactly as `cron.job` holds it on production, read 2026-10-06 (whitespace
-- trimmed). `cron.schedule` with an existing name updates that job in place (pg_cron 1.6.4, the
-- version on the node), so on production this re-asserts what is already there and changes no
-- `jobid`; on a rebuild it creates them. Everything they call (`market.cron_post`,
-- `market.cron_tick`, `market.cron_sample`) is in the baseline, and `cron_post` reads its key from
-- Vault, which Ansible fills, so no secret is here.
--
-- A LATER CHANGE TO ONE OF THESE IS ITS OWN MIGRATION, like the four since the baseline: this file
-- records them as of today and runs once.
--
-- Guarded on the relation: the migration tests run on plain Postgres with no pg_cron.

do $$
declare
  job record;
begin
  if to_regclass('cron.job') is null then
    raise notice '  --  no pg_cron here (the migration tests): nothing to schedule';
    return;
  end if;
  for job in
    select * from (values
      ('muffin-rotation',       '*/5 * * * *',      $c$select market.cron_tick()$c$),
      ('muffin-observability',  '4 * * * *',        $c$select market.cron_sample()$c$),
      ('muffin-cron-prune',     '17 4 * * *',       $c$delete from cron.job_run_details where end_time < now() - interval '30 days'$c$),
      ('muffin-facets',         '14 * * * *',       $c$select market.cron_post('facets-refresh')$c$),
      ('muffin-metrics',        '24,54 * * * *',    $c$select market.cron_post('security-metrics')$c$),
      ('muffin-segments',       '2-59/5 * * * *',   $c$select market.cron_post('security-segments')$c$),
      ('muffin-filing-history', '9-59/15 * * * *',  $c$select market.cron_post('security-filing-history')$c$),
      ('muffin-kr-segments',    '4-59/5 * * * *',   $c$select market.cron_post('security-kr-segments')$c$),
      ('muffin-kr-filings',     '11-59/15 * * * *', $c$select market.cron_post('kr-filings')$c$),
      ('muffin-in-segments',    '7-59/5 * * * *',   $c$select market.cron_post('security-in-segments')$c$),
      ('muffin-in-filings',     '13-59/15 * * * *', $c$select market.cron_post('in-filings')$c$),
      ('muffin-cn-filings',     '21-59/30 * * * *', $c$select market.cron_post('cn-filings')$c$)
    ) as j(name, schedule, command)
  loop
    -- DYNAMIC, as in the four migrations since the baseline: nothing names `cron` until the
    -- guard has passed.
    execute 'select cron.schedule($1, $2, $3)' using job.name, job.schedule, job.command;
  end loop;
  raise notice '  ++  12 legacy pg_cron jobs declared';
end $$;
