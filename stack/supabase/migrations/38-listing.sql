-- Where a security actually trades — IDEMPOTENT.
--
-- THE GAP. `exchange_listing` holds 59,324 venue rows from OpenFIGI and has NO `security_id`. It
-- joins to securities only through `composite_figi` against a `figi` identifier, and just 536 of
-- 10,060 securities carry one — so 99% of those listings float unattached. Meanwhile a security's
-- venue was implied by a string suffix on `security_provider_symbol` and nowhere stated.
--
-- That is why "local line vs ADR" has no answer today, why the ISIN resolver throws away every
-- listing except the one it picks, and why `security_provider_symbol` — keyed
-- `(security_id, provider_code)` — structurally cannot say "the provider knows this security on
-- three venues".
--
-- THE TWO TABLES ARE DIFFERENT THINGS and both are worth keeping:
--   `exchange_listing`  the raw venue DIRECTORY: everything OpenFIGI reports on an exchange,
--                       including companies no tracked fund holds. `untracked_listing` reads it to
--                       offer promotions.
--   `listing`           venues for securities we DO track, linked by `security_id`.
--
-- POPULATED FROM THE PROVIDER SYMBOL, NOT THE FIGI. Measured 2026-08-12: 8,522 securities have a
-- yfinance provider symbol and every one carries the venue in its suffix, against 536 reachable
-- through FIGI. The weaker key would have made this table look built and stay empty.

create table if not exists market.listing (
  security_id     uuid not null references market.security (security_id) on delete cascade,
  exch_code       text not null references market.exchange (exch_code),
  -- The ticker as the venue quotes it (`005930`), without the provider's suffix.
  symbol          text,
  -- What the price provider calls it (`005930.KS`). This is what actually gets fetched.
  provider_symbol text,
  -- The venue-level FIGI. Captured opportunistically; not the join key, for the reason above.
  figi            text,
  -- The listing this security is normally priced and reported on. Exactly one per security is
  -- enforced below, because "which line is the real one" is the question the table exists to answer.
  is_primary      boolean not null default false,
  source_code     text references market.data_source (code),
  first_seen_at   timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  primary key (security_id, exch_code)
);

create index if not exists listing_security_idx  on market.listing (security_id);
create index if not exists listing_exch_idx      on market.listing (exch_code);
create unique index if not exists listing_one_primary_idx
  on market.listing (security_id) where is_primary;

comment on table market.listing is
  'Venues a TRACKED security trades on. `exchange_listing` is the raw OpenFIGI directory including untracked companies; this is the linked subset. Populated from the provider symbol, whose suffix names the venue — the FIGI join reaches only 536 of 10,060 securities.';

-- ── backfill: the suffix on a provider symbol names its venue ────────────────
-- Longest suffix first so `.SS` cannot be matched by a shorter one, then `preference` so a country
-- with two venues sharing a suffix (Canada CT/CN both `.TO`, UAE DU/DH both `.AE`) resolves to its
-- primary board rather than whichever row the planner reached first.
insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code)
select
  ps.security_id,
  e.exch_code,
  left(ps.symbol, length(ps.symbol) - length(e.suffix)),
  ps.symbol,
  true,
  'openfigi'
from market.security_provider_symbol ps
join lateral (
  select ex.exch_code, ex.suffix
  from market.exchange ex
  where ex.enabled
    and ex.suffix <> ''
    and ps.symbol like '%' || ex.suffix
  order by length(ex.suffix) desc, ex.preference
  limit 1
) e on true
where ps.provider_code = 'yfinance'
on conflict (security_id, exch_code) do nothing;

-- A provider symbol with NO suffix is a US listing. Handled separately because matching an empty
-- suffix with `like '%'` would match every symbol on every venue.
insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code)
select ps.security_id, 'US', ps.symbol, ps.symbol, true, 'openfigi'
from market.security_provider_symbol ps
where ps.provider_code = 'yfinance'
  and ps.symbol not like '%.%'
on conflict (security_id, exch_code) do nothing;

-- The ticker identifier is a US listing too when the security has no provider symbol at all —
-- that is how a US-only security is addressed. `not exists` rather than a left join: this must be
-- one row per security, and a security with several ticker identifiers would otherwise multiply.
insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code)
select distinct on (t.security_id) t.security_id, 'US', t.value, t.value, true, 'openfigi'
from market.security_identifier t
where t.kind_code = 'ticker'
  and t.value not like '%.%'
  and not exists (select 1 from market.listing l where l.security_id = t.security_id)
order by t.security_id, t.value
on conflict (security_id, exch_code) do nothing;

grant select on market.listing to anon, authenticated, service_role;

notify pgrst, 'reload schema';
