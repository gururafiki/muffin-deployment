-- THE SEC FAMILY LEAVES THE EDGE (Phase 5 step 9; decided 2026-10-20..24, umbrella
-- docs/specs/2026-10-24-sec-family.md).
--
-- The Dagster SEC lanes have owned what these resources wrote since the step-8 backfills:
--   - `security-xbrl` (company facts → `security_metric` `sec-xbrl`): `sec_statement` now writes
--     each filer's statements from the same document, and `derived_security_metrics` derives the
--     metrics with fiscal labels. The whole grid (~3,700 filers) was collected 2026-10-30..11-02.
--   - `security-filings` (openbb, recent 40 forms) and `security-filing-history` (submissions):
--     `sec_filing` writes every filing from the submissions document, links included (`report_url`
--     and `filing_detail_url`, byte-identical to openbb's for Apple).
--   - `security-insider` (openbb, per ticker): the Form 4 lane reads every Form 4 named in SEC's
--     daily index. Measured 2026-11-07: its rows cover 67 filing days, 2026-08-03..11-05, so the
--     summary's whole 90-day window.
--   - `security-eps-history` (alpha_vantage, 25 calls a day): unscheduled since legacy migration 138
--     and still reachable. Its backlog has sat FLAT at 309 since, which the flat-backlog alert
--     excluded by name.
--
-- RETIRES: security-xbrl, security-filings, security-filing-history, security-insider, security-eps-history
--
-- Each name is in `index.ts`'s `RETIRED` map, which answers 410 before the admin gate. The handlers
-- stay until step 10 (three clean days), so rolling back is re-enabling the rows below and removing
-- the map entries, plus re-creating the backlog views from git.
--
-- The backlog views go now rather than at the contract, as `pending_price_targets` did: nothing can
-- reach their resources, and they are what the backlog alerts sample (`pending_insider` 2,303 and
-- growing, `pending_eps_history` 309 and flat). The cursor and negative-cache COLUMNS they read
-- (`xbrl_fetched_at`, `xbrl_missing_at`, `filings_fetched_at`, `filing_history_fetched_at`,
-- `insider_fetched_at`, `eps_history_fetched_at`) stay until step 11, which drops them with dates.
--
-- `security_insider_summary` now counts only rows that name their filing. Until today it also kept
-- an edge row (no accession) for a filing day the lane had not collected; with the edge retired the
-- lane is the only writer, and its days cover the window.

update market.cron_resource set enabled = false
 where resource in ('security-xbrl', 'security-filings', 'security-filing-history',
                    'security-insider', 'security-eps-history');

do $$
begin
  -- pg_cron is absent from the migration tests' Postgres; even planning a query naming it fails.
  if to_regclass('cron.job') is not null then
    execute $q$select cron.unschedule(jobname) from cron.job where jobname = 'muffin-filing-history'$q$;
  end if;
end $$;

delete from market.backlog_negative_cache
 where backlog in ('pending_xbrl', 'pending_filing_history', 'pending_filings',
                   'pending_insider', 'pending_eps_history');

do $$
declare
  v text;
  k char;
begin
  foreach v in array array['pending_xbrl', 'pending_filing_history', 'pending_filings',
                           'pending_insider', 'pending_eps_history'] loop
    -- relkind-aware: `drop view if exists` raises on a materialized view of the same name.
    select c.relkind into k
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'market' and c.relname = v;
    if k = 'v' then
      execute format('drop view market.%I', v);
    elsif k = 'm' then
      execute format('drop materialized view market.%I', v);
    end if;
    k := null;
  end loop;
end $$;

-- Same columns, so `create or replace` keeps the view's grants.
create or replace view market.security_insider_summary as
 SELECT security_id,
    count(*) FILTER (WHERE direction = 'Acquisition'::text) AS buys,
    count(*) FILTER (WHERE direction = 'Disposition'::text) AS sells,
    count(DISTINCT owner_name) FILTER (WHERE direction = 'Acquisition'::text) AS buyers,
    count(DISTINCT owner_name) FILTER (WHERE direction = 'Disposition'::text) AS sellers,
    COALESCE(sum(shares) FILTER (WHERE direction = 'Acquisition'::text), 0::numeric) - COALESCE(sum(shares) FILTER (WHERE direction = 'Disposition'::text), 0::numeric) AS net_shares,
    max(transaction_date) AS latest,
    count(*) AS trades
   FROM market.insider_trade t
  WHERE transaction_date >= (CURRENT_DATE - 90) AND accession_number IS NOT NULL AND (form_type IS DISTINCT FROM '4'::text OR NOT (EXISTS ( SELECT 1
           FROM market.insider_trade a
          WHERE a.security_id = t.security_id AND a.owner_cik = t.owner_cik AND a.transaction_date = t.transaction_date AND a.is_derivative = t.is_derivative AND a.transaction_code = t.transaction_code AND a.form_type = '4/A'::text AND a.filing_date >= t.filing_date)))
  GROUP BY security_id;
