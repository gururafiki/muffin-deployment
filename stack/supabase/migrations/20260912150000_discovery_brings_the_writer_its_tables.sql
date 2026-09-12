-- Discovery: the OpenFIGI venue directory, additively beside `exchange_listing`, and the grants
-- the writer role needs to resolve N-PORT filings onto the identity tables.
--
-- THE GRANTS ARE THE PART THAT WOULD BE INVISIBLE, AND THAT IS WHY THEY ARE HERE. The price lane
-- paid this exact migration once (`ingest_rw_can_write`): a Dagster asset wrote every table through
-- `service_role` and the first real run died on `new row violates row-level security policy`,
-- because the migration tests run as SUPERUSER and cannot see a grant or an RLS policy. Ingestions
-- new write into `market.security` / `security_identifier` / `issuer` / `fund_holding` as
-- `ingest_rw` — which holds no DML on any of them — so this file both ships the new table and re-
-- issues the grants the writer needs, in the shape the D1 price migration uses.

-- ── 1. the raw OpenFIGI directory, beside the old one ──────────────────────────────────────────
--
-- ADDITIVE ON PURPOSE. `exchange_listing` is still the edge function's directory until the model
-- cutover (step 6); this table is the same shape because that step is a rename, and a table that
-- already matched its successor makes the cutover a data move rather than a model change.
create table if not exists market.venue_listing (
    figi               text primary key,
    composite_figi     text,
    exch_code          text not null,
    ticker             text not null,
    name               text,
    security_type      text,
    country_iso2       text,
    provider_symbol    text,
    first_seen_at      timestamptz not null default now(),
    last_seen_at       timestamptz not null default now(),
    -- The FINE OpenFIGI type (`securityType`), beside the coarse `security_type` (`securityType2`).
    -- An ETF is `ETP` inside `Mutual Fund`, a receipt `ADR` inside `Depositary Receipt` — the coarse
    -- value is what a stock sweep filters on and cannot name either of those.
    figi_security_type text
);

comment on table market.venue_listing is
  'The raw OpenFIGI directory, one row per listing. Written by the Dagster exchange sweep; '
  '`exchange_listing` remains until the model cutover renames it to this.';

-- ── 2. the writer role can actually write the identity tables ──────────────────────────────────
--
-- The reader queries inside the discovery assets also need SELECT on the small control tables
-- (`countries`, `tracked_fund`, `exchange`), which `ingest_rw` has never had.
grant select, insert, update, delete on
  market.security, market.security_identifier, market.issuer, market.fund_holding
  to service_role, ingest_rw;

grant select on
  market.countries, market.tracked_fund, market.exchange
  to ingest_rw;

-- ── 3. reachability, the convention every `market` table follows ────────────────────────────────
grant select, insert, update, delete on market.venue_listing to service_role, ingest_rw;
grant select on market.venue_listing to anon, authenticated;

alter table market.venue_listing enable row level security;
create policy venue_listing_public_read on market.venue_listing for select using (true);
