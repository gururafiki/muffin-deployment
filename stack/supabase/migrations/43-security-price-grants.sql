-- `security_price` was created without grants or RLS — IDEMPOTENT.
--
--   [Error] market-refresh(security-prices) failed: security_price upsert failed:
--           permission denied for table security_price
--
-- Migration 42 granted the two VIEWS (`price_series`, `pending_prices`) and forgot the table they
-- read. The edge function writes through PostgREST as `service_role`, which bypasses RLS but still
-- needs the grant, so the resource could not write a single row.
--
-- Caught by the ingestion watch within minutes of the deploy — the second failure it has found
-- today, after the currency foreign key. Both were "a new table works locally and is unreachable in
-- production", and both were invisible to the migration tests, which apply DDL as a superuser and
-- therefore never exercise a grant.
--
-- RLS FOLLOWS THE HOUSE RULE. Every `market` table has row-level security with an explicit policy
-- (09-market-rls.sql) rather than relying on grants alone: grants left `rls_disabled_in_public` on
-- the advisor and were one stray `grant` away from being wrong. Daily closes are public data — the
-- chart reads them anonymously — so this gets the same public-read policy as `prices`.

alter table market.security_price enable row level security;

do $$ begin
  create policy security_price_public_read on market.security_price for select to public using (true);
exception when duplicate_object then null; end $$;

-- anon/authenticated read the chart; service_role writes and prunes the rolling window.
grant select on market.security_price to anon, authenticated, service_role;
grant insert, update, delete on market.security_price to service_role;

-- THE SAME OMISSION IN TWO MORE TABLES FROM TODAY, found by the new reachability test the moment it
-- was written — not in production this time.
--
-- `listing` is the live one: the ISIN resolver upserts into it on every run, so it would have
-- failed with "permission denied" the first time it found a security's other venues. The backfill
-- in migration 38 worked only because a migration runs as the owner.
--
-- `exchange` is not written today, but a venue catalog whose whole point is "adding one is a row"
-- should not be read-only to the role that does the adding.
grant insert, update, delete on market.listing  to service_role;
grant insert, update, delete on market.exchange to service_role;

notify pgrst, 'reload schema';
