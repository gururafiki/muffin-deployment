-- A STATEMENT IS KEYED BY ITS PROVIDER (Phase 5 step 2b; decision 6, the user, 2026-10-20..24).
--
-- WHY. `security_statement` was keyed (security, statement, period_ending, period_type), so one
-- provider's row for a period excluded every other's. The Yahoo writer kept SEC's rows only by
-- refusing to replace them (`only_replacing`), so Yahoo's answer for those periods was fetched and
-- dropped. And SEC's company-facts statements (`sec-xbrl`, step 3) would have been refused wherever
-- Yahoo or the old `sec` route already held the date. The decided rule: every ingested row keeps a
-- reference to its provider, and where two providers state one fact, the provider is in the key.
-- Serving views choose by `source_priority` (`security_statement_current`, 20261025110000) and the
-- derivation keeps one statement per metric key (20261025100100).
--
-- WHAT.
--   * The primary key becomes `security_statement_provider_key` (source_code added), built in
--     20261025100200. Every column is NOT NULL and nothing references the table, so the swap is a
--     catalogue change under a brief ACCESS EXCLUSIVE lock, with no scan.
--   * `FY` becomes `annual`. Measured 2026-10-25: 2,259 `FY` rows, all `sec`, written 2026-08-20/21
--     for 59 securities; none collides with a `sec` annual row, and 763 collide with a yfinance
--     annual row under the OLD key only. So the conversion follows the swap and deletes nothing. The
--     live writers already write `annual`.
--   * `period_type` is checked to annual, quarter or half, NOT VALID here and validated in the next
--     file, so the scan runs without this file's ACCESS EXCLUSIVE lock.
--   * `security-statements` (SEC through openbb, annual, fetched once) retires: it upserts on the
--     old key, which no longer exists. SEC statements come from company facts in step 3.
--     Measured: its queue held 5 securities, every one already marked absent at SEC.
--
-- RETIRES: security-statements
--
-- Its backlog view and negative-cache pairing go with it, as Tiingo's did (20261025120000); the
-- handler and `statement_currency_missing_at` leave at the contract (step 11).
-- The three tests that asserted only the view's population leave with it
-- (sec-is-only-asked-where-it-can-answer, a-statement-without-a-currency-is-not-done,
-- sec-is-asked-by-its-own-spelling). The spelling rule the last one guarded does not carry over:
-- the Dagster SEC lane asks company facts by CIK, never by ticker.
-- Guard: tests/a-statement-is-keyed-by-its-provider.sql.
--
-- ORDER. The Yahoo writer upserts on the old key until muffin-ingest rolls onto the new one, so this
-- deploys and the ingest image rolls in one window, outside the company lane (03:30-06:00 UTC).

update market.cron_resource set enabled = false where resource = 'security-statements';

delete from market.backlog_negative_cache where backlog = 'pending_statements';

do $$
declare k char;
begin
  select c.relkind into k
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_statements';
  if k = 'v' then
    execute 'drop view market.pending_statements';
  elsif k = 'm' then
    execute 'drop materialized view market.pending_statements';
  end if;
end $$;

do $$
begin
  -- IDEMPOTENT: a database built from these migrations reaches here once, but the guard's
  -- mutation replay re-applies this file over a database with the old key restored.
  if exists (select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
              where i.indrelid = 'market.security_statement'::regclass and i.indisprimary
                and c.relname = 'security_statement_pkey'
                and i.indnatts = 4) then
    alter table market.security_statement drop constraint security_statement_pkey;
    alter table market.security_statement
      add constraint security_statement_pkey primary key using index security_statement_provider_key;
  end if;
end $$;

update market.security_statement set period_type = 'annual' where period_type = 'FY';

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'market.security_statement'::regclass
                    and conname = 'security_statement_period_type_check') then
    alter table market.security_statement
      add constraint security_statement_period_type_check
      check (period_type in ('annual', 'quarter', 'half')) not valid;
  end if;
end $$;
