-- SIX FIELDS FROM A RESPONSE THIS PIPELINE HAS BEEN FETCHING AND DISCARDING ALL ALONG.
--
-- `security-profiles` calls `equity/profile` for every security and reads the sector, the market cap
-- and the operating country off it. The same response carries `long_description`, `employees`,
-- `company_url`, `hq_address_city/state/country` and `beta` — a company page's entire identity —
-- and every one was thrown away. Sixth instance of "the answer is already in a response you fetch".
--
-- ── BUT IT IS NOT "ZERO NEW CALLS", AND SAYING SO WOULD BE WRONG ────────────────────────────────
--
-- The plan called this free because the resource already runs. It is not: `pending_profile` asks for
-- securities with no SECTOR and is DRAINED (33 rows), so extending that handler would fetch nothing
-- and these columns would sit empty — exactly what migration 56 did with `provider_country_iso2`,
-- which reached production at 0 rows populated while the resource reported success. A new field
-- filled by an existing resource needs its own backlog or it is inert.
--
-- The good news is the cost: `equity/profile` BATCHES (measured — three symbols, three rows), so
-- this is one call per 20 securities rather than the three-per-security that makes
-- `security-quarters` expensive.
--
-- ── A SEPARATE TABLE, NOT COLUMNS ON `security` ─────────────────────────────────────────────────
--
-- `long_description` is a paragraph. `market.security` is joined by `security_current`, the
-- `security_facets` spine matview and every serving view in the schema; widening the hot table with
-- kilobytes of prose to serve one page would slow all of them. A 1:1 detail table is read only by
-- the page that wants it.

create table if not exists market.security_profile (
  security_id  uuid primary key references market.security (security_id) on delete cascade,
  description  text,
  employees    integer,
  website      text,
  hq_city      text,
  hq_state     text,
  -- The provider's own string, deliberately NOT a foreign key to `countries`. This is where the
  -- company says it is headquartered, which is a display fact; `security.country_iso2` and
  -- `provider_country_iso2` remain the ones anything JOINS on. An unmatched name here should render
  -- as itself, not abort an ingest — N-PORT's `XX` already cost one 584-holding fund that way.
  hq_country   text,
  beta         numeric,
  source_code  text not null references market.data_source (code),
  as_of        timestamptz not null default now()
);

comment on table market.security_profile is
  'Descriptive company identity from `equity/profile` — the fields `security-profiles` was fetching and discarding. A separate table because `description` is a paragraph and `market.security` is joined by the spine matview and every serving view.';

-- The negative cache. A security the provider carries no profile for must leave the backlog, or it
-- crowds out the ones that would answer.
alter table market.security add column if not exists profile_detail_missing_at timestamptz;

comment on column market.security.profile_detail_missing_at is
  'Set when `equity/profile` was asked about this symbol ALONE and returned no descriptive fields. Distinct from `profile_missing_at`, which is about the sector.';

create or replace function market.clear_symbol_caches(p_security_id uuid)
returns void language sql as $$
  update market.security set
    industry_missing_at         = null,
    profile_missing_at          = null,
    performance_missing_at      = null,
    fundamentals_missing_at     = null,
    statements_missing_at       = null,
    prices_missing_at           = null,
    quarters_missing_at         = null,
    provider_country_missing_at = null,
    corporate_actions_missing_at = null,
    dividends_missing_at        = null,
    price_history_missing_at    = null,
    share_stats_missing_at      = null,
    estimates_missing_at        = null,
    profile_detail_missing_at   = null
  where security_id = p_security_id;
$$;

grant execute on function market.clear_symbol_caches(uuid) to service_role;

drop view if exists market.symbol_cache_classification;
create view market.symbol_cache_classification as
select * from (values
  ('industry_missing_at',          true,  'yfinance profile fetched by symbol'),
  ('profile_missing_at',           true,  'yfinance profile fetched by symbol'),
  ('profile_detail_missing_at',    true,  'yfinance profile fetched by symbol'),
  ('performance_missing_at',       true,  'historical bars fetched by symbol'),
  ('fundamentals_missing_at',      true,  'metrics fetched by symbol'),
  ('statements_missing_at',        true,  'statements fetched by symbol'),
  ('prices_missing_at',            true,  'daily bars fetched by symbol'),
  ('quarters_missing_at',          true,  'quarterly statements fetched by the PRICED symbol'),
  ('provider_country_missing_at',  true,  'yfinance profile fetched by symbol'),
  ('corporate_actions_missing_at', true,  'Tiingo EOD fetched by the US ticker'),
  ('dividends_missing_at',         true,  'yfinance dividends fetched by the PRICED symbol'),
  ('price_history_missing_at',     true,  'weekly history fetched by the PRICED symbol'),
  ('share_stats_missing_at',       true,  'share statistics fetched by the PRICED symbol'),
  ('estimates_missing_at',         true,  'analyst consensus fetched by the PRICED symbol'),
  ('figi_missing_at',              false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at',      false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at',      false, 'the resolver''s own flag — clearing it here would loop'),
  ('statement_currency_missing_at', false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'),
  ('xbrl_missing_at',              false, 'company facts are asked for by CIK; a new provider symbol says nothing about the filer')
) as t(column_name, symbol_keyed, reason);

comment on view market.symbol_cache_classification is
  'Which negative caches a new symbol invalidates, and why. Enforced by tests/negative-caches-are-classified.sql: a `%_missing_at` column missing from here fails CI.';

grant select on market.symbol_cache_classification to service_role;

-- ── THE BACKLOG ─────────────────────────────────────────────────────────────────────────────────
--
-- Scoped to equities with a symbol, ordered by FUND WEIGHT — a percentage is free of currency,
-- market cap and country, and 34% of the universe has no cap at all. The anti-join is over the
-- SECURITY (does it have a profile row), not a `where` over rows.
drop view if exists market.pending_profile_detail;
create view market.pending_profile_detail as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_profile p on p.security_id = s.security_id
left join market.fund_holding_current h on h.security_id = s.security_id
where p.security_id is null
  and s.security_type_code = 'equity'
  and coalesce(ps.symbol, t.value) is not null
  and (s.profile_detail_missing_at is null
       or s.profile_detail_missing_at < now() - interval '30 days')
group by s.security_id, coalesce(ps.symbol, t.value)
order by best_weight desc;

comment on view market.pending_profile_detail is
  'Equities with no descriptive profile, ordered by fund weight. Its own backlog rather than a widened `pending_profile`, which asks about the SECTOR and is drained — a new field filled by an existing resource is inert without one.';

grant select on market.pending_profile_detail to service_role;
grant select on market.security_profile to anon, authenticated, service_role;
grant insert, update on market.security_profile to service_role;

alter table market.security_profile enable row level security;

drop policy if exists security_profile_read on market.security_profile;
create policy security_profile_read on market.security_profile for select using (true);

notify pgrst, 'reload schema';
