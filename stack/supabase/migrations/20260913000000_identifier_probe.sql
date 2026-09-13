-- The identity ladder's observation table, and the one-per-security symbol constraint.
--
-- `identifier_probe` records what the ladder ASKED and what the provider SAID, per security — the
-- ordinary observation the design (Phase 3 §2.3) puts here instead of on `market.security` and its
-- `%_missing_at` columns. It is a ROW WRITE, not a control surface: hit and miss are both recorded,
-- a throttled subject is recorded by NOT materialising its partition (never as a miss), and the
-- re-ask sensor reads `outcome = 'miss'` older than 30 days.

create table if not exists market.identifier_probe (
    security_id uuid not null,
    scheme      text not null,
    provider    text not null,
    asked_with  text,
    value       text,
    outcome     text not null check (outcome in ('hit', 'miss')),
    observed_at timestamptz not null default now(),
    primary key (security_id, scheme, provider)
);

comment on table market.identifier_probe is
  'What the identity ladder asked and what the provider said — one row per (security, scheme, '
  'provider), the latest observation winning. outcome=miss means ASKED AND ANSWERED WITH NOTHING, '
  'never that the run failed.';

-- One provider symbol per security: the ladder writes (security_id, provider_code) and needs that
-- to be a unique upsert target. The table's existing UNIQUE is (provider_code, symbol), which would
-- let one security accumulate drifted symbols; the writer must be able to REPLACE a corrected one.
create unique index if not exists security_provider_symbol_one_per_security
    on market.security_provider_symbol (security_id, provider_code);

-- Reachability, the convention every `market` table follows.
grant select, insert, update, delete on market.identifier_probe to service_role, ingest_rw;
grant select on market.identifier_probe to anon, authenticated;

alter table market.identifier_probe enable row level security;
create policy identifier_probe_public_read on market.identifier_probe for select using (true);
