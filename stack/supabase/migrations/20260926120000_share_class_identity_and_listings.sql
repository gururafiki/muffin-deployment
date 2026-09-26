-- SHARE-CLASS IDENTITY, AND A PLACE FOR THE LISTINGS OF A TRACKED SECURITY.
--
-- Decided with the user on 2026-09-26 (docs/specs/2026-09-26-finishing-the-universe-family.md in
-- the umbrella): an equity is one OpenFIGI SHARE CLASS, and its listings are the venue lines the
-- directory already holds for that share class.
--
-- Why the share class and not what we key on today, measured the same day:
--
--   * The directory's 99,459 listings are 54,332 share classes; 23,849 of them trade on more than
--     one venue. A company is one share class and many lines, and our model had no way to say so.
--   * With the share class known for only 1,395 tracked securities, 5,946 of the 84,201 rows
--     `untracked_listing` offers as "not tracked yet" are ALREADY TRACKED — Frankfurt, Swiss and
--     Mexican lines of companies we hold. A promotion wave would mint them as duplicates.
--   * A composite FIGI is per COUNTRY of listing (CLAUDE.md), so it cannot be the join; the share
--     class FIGI is the one OpenFIGI key that is the same on every venue.
--   * 838 (share class, venue) pairs have MORE THAN ONE line — Argentina's BMA, BMA/C and BMAD are
--     one share class on one venue — so a listing is keyed by its own FIGI, never by
--     (security, venue), which is what `market.listing`'s primary key assumes.
--
-- `security_identifier` keeps its (kind_code, value) key: for a share class that key IS the rule
-- "one security per share class". The surrogate key the 09-12 spec planned is dropped — the
-- four-company collapse it was meant to prevent came from a placeholder CUSIP, which is refused at
-- ingest now.
--
-- ADDITIVE ONLY. Nothing reads the new column or table yet; `market.listing` keeps serving until a
-- later migration makes it a view over this table, after a parity check against its 12,482 rows.

-- ── 1. the identifier kind ─────────────────────────────────────────────────────────────────────
insert into market.identifier_kind (code, name, is_global_unique)
values ('share_class_figi', 'OpenFIGI share-class FIGI — the same on every venue a class trades on', true)
on conflict (code) do nothing;

-- ── 2. the directory says which share class each line belongs to ───────────────────────────────
-- Every stored sweep page already carries `shareClassFIGI` (21 of 99,459 lines lack one); the
-- stage-2 parse dropped it. Filled by re-materialising `venue_listing` from the raw files — no
-- provider request.
alter table market.venue_listing add column if not exists share_class_figi text;
create index if not exists venue_listing_share_class_figi_idx
    on market.venue_listing (share_class_figi);

-- ── 3. the listings of a tracked security ───────────────────────────────────────────────────────
--
-- THIRD NORMAL FORM: a line's ticker, venue and name live in `venue_listing` and are not copied
-- here. This table holds what the directory cannot know: which security a line belongs to, which
-- line is primary (the one we price with), and the line's quote currency. Written by the Dagster
-- `security_listing` asset from `venue_listing` ⋈ the share-class identifier.
--
-- `currency_code` is a fact about the LINE — one share class quotes in EUR in Frankfurt and USD in
-- New York — and OpenFIGI's directory does not carry it. It starts as what `market.listing` holds
-- (11,547 securities take their currency from there through `security_currency`) and is never
-- overwritten by the derivation, so it survives `market.listing` being retired. A line promoted
-- later has none until a lane that sees the quote currency fills it (docs/deferred, Phase 4).
create table if not exists market.security_listing (
    figi          text primary key references market.venue_listing (figi) on delete cascade,
    security_id   uuid not null references market.security (security_id) on delete cascade,
    is_primary    boolean not null default false,
    currency_code text references market.currency (code),
    first_seen_at timestamptz not null default now(),
    last_seen_at  timestamptz not null default now()
);

create index if not exists security_listing_security_idx on market.security_listing (security_id);

-- ONE PRIMARY PER SECURITY. A partial unique index is not covered by `on conflict`, so the writer
-- moves the flag in two statements (demote, then promote) — the lesson migration 38 paid for.
create unique index if not exists security_listing_one_primary
    on market.security_listing (security_id) where is_primary;

comment on table market.security_listing is
  'The venue lines of each tracked security, keyed by the line''s own FIGI (a share class can have '
  'several lines on one venue). Derived by the Dagster asset `security_listing` from venue_listing '
  'and the share_class_figi identifier; is_primary marks the line the security is priced with.';

-- ── 4. reachability, the convention every `market` table follows ────────────────────────────────
-- Grants and RLS are independent gates: the writer needs both, and a correct grant hides a missing
-- policy until the first real write (`ingest_rw` holds BYPASSRLS, measured 2026-09-20, which is
-- why the writer needs no policy of its own).
grant select, insert, update, delete on market.security_listing to service_role, ingest_rw;
grant select on market.security_listing to anon, authenticated;

alter table market.security_listing enable row level security;
drop policy if exists security_listing_public_read on market.security_listing;
create policy security_listing_public_read on market.security_listing for select using (true);
