-- MACRO SERIES, MODELLED AS A CONTROL TABLE — adding one is a row, never a migration.
--
-- The same shape as `market.tracked_fund`, and for the same reason: which ETFs the universe is
-- built from is an editorial decision that lives in the database, so an operator can add one in
-- Studio without a deploy. Which macro series a country page shows is the same kind of decision.
--
-- ── WHAT IS ACTUALLY AVAILABLE, MEASURED 2026-08-19 ──────────────────────────────────────────
--
-- ECONDB IS FREE. An earlier revision of this header said its data was not, inferring a paywall
-- from a 204 and "no key configured". That was wrong, and the correction is worth more than the
-- original claim.
--
-- What actually happens: `openbb_econdb` declares an `econdb_api_key` credential but
-- SELF-PROVISIONS when none is set — `helpers.create_token()` fetches a free 24-hour token, no
-- account required. From this node that call returns 403 on every User-Agent, `create_token`
-- SWALLOWS the failure and returns an empty string, the data request goes out with `token=`, and
-- the result surfaces as a bare 204. From another IP the same endpoint returns 200 with a token.
--
-- The block is one ENDPOINT, not the domain and not the data. From the node:
-- `econdb.com/` -> 200, `/user/create_token/` -> 403, and `api/series/?token=<minted elsewhere>`
-- -> 200 with `count: 5170`. So setting ECONDB_API_KEY unblocks the whole catalogue; the node can
-- talk to econdb perfectly well, it just cannot mint its own credential. A free econdb account
-- yields a permanent key. The temporary token also works and expires daily, which is not a
-- deployment strategy.
--
-- The seed below therefore carries what needs NO credential at all. Adding econdb series is a
-- ROW once a key is set — which is the entire point of this being a control table, and why the
-- key question does not block the schema.
--
-- Two parameter facts recorded so nobody re-derives them: the query wants `symbol_root` +
-- `country` (the composite `RGDPUS` 400s with "No valid combination of indicator symbols and
-- countries were supplied" — far more useful than the 204), and `country` is the lower-underscore
-- form, so the catalogue's own "United States" produces an unencoded space and never leaves curl.
--
-- So the seed below is ONLY series measured to return rows, not merely a 200:
--
--   economy/cpi                    oecd              multi-country, 84 rows for 4 countries
--   economy/gdp/real, /nominal     oecd
--   economy/unemployment           oecd
--   fixedincome/government/yield_curve  federal_reserve   11 maturities
--   fixedincome/rate/effr, /sofr   federal_reserve   400+ rows
--   derivatives/futures/historical yfinance          GC=F, CL=F
--   crypto/price/historical        yfinance          BTC-USD
--   index/price/historical         yfinance          ^GSPC
--
-- NOT seeded: econdb series (they need ECONDB_API_KEY set first — see above; they are a row away,
-- not a redesign) and yield_curve via ecb (500). Seeding a series that cannot answer would put a
-- permanently empty panel on a country page and make the resource look broken — the same reason
-- the period picker only offers periods the provider actually serves.
--
-- ── WHY OBSERVATIONS CARRY A `dimension` ─────────────────────────────────────────────────────
--
-- Most series are (indicator, country, date) -> value. A YIELD CURVE is not: it is a term
-- structure, (date, maturity) -> rate, and flattening it into one row per date would either lose
-- the curve or need a table per shape. `dimension` holds the maturity (`month_1`, `year_10`) and is
-- NULL for the scalar series, which keeps one table honest for both rather than inventing a second.

create table if not exists market.macro_indicator (
  code            text primary key,
  name            text not null,
  category        text not null,
  -- The openbb route and provider this series comes from. Stored rather than hardcoded in the
  -- edge function so a new series is a row: the resource reads this table and drives what it finds.
  route           text not null,
  provider        text not null,
  -- Extra query parameters as (key -> value), e.g. {"symbol": "GC=F"}. jsonb rather than columns
  -- because the routes genuinely differ in what they take.
  params          jsonb not null default '{}'::jsonb,
  -- ISO-2 of the country this series describes, NULL for a global series (gold, BTC, an index).
  country_iso2    text references market.countries(iso2),
  -- The `country` value the PROVIDER wants, which is not the ISO code and not the display name —
  -- `united_states`, lower-underscore. Null where the route takes no country.
  provider_country text,
  frequency       text,
  unit            text,
  -- FRACTION vs PERCENT is the single most expensive ambiguity in this pipeline (a 46% dividend
  -- yield rendered on the deployed page). Recorded per series rather than guessed per reader.
  value_is_fraction boolean not null default false,
  enabled         boolean not null default true,
  sort_order      integer not null default 100,
  notes           text
);

create table if not exists market.macro_observation (
  indicator_code  text not null references market.macro_indicator(code) on delete cascade,
  as_of           date not null,
  -- The term-structure axis (a yield curve's maturity). Empty string rather than NULL so it can sit
  -- in a primary key — NULL would let the same (indicator, date) be inserted repeatedly.
  dimension       text not null default '',
  value           numeric not null,
  fetched_at      timestamptz not null default now(),
  primary key (indicator_code, as_of, dimension)
);

create index if not exists macro_observation_indicator_idx
  on market.macro_observation (indicator_code, as_of desc);

comment on table market.macro_indicator is
  'The macro series this deployment serves, as a CONTROL TABLE — adding one is a row, never a migration, the same shape as tracked_fund. Only series MEASURED to return rows are seeded: econdb''s 4,506-indicator catalogue is free but its data returns 204 without a key, so nothing here depends on it.';
comment on column market.macro_indicator.provider_country is
  'The country value the PROVIDER wants (`united_states`) — not the ISO2 code and not the display name. The catalogue''s own "United States" contains a space and is not a usable value.';
comment on table market.macro_observation is
  'One value per (series, date, dimension). `dimension` carries a yield curve''s maturity and is empty for scalar series, so a term structure and a single number share one table.';

-- ── the seed: ONLY what was measured to return rows ──────────────────────────────────────────
insert into market.macro_indicator
  (code, name, category, route, provider, params, country_iso2, provider_country, frequency, unit, value_is_fraction, sort_order)
values
  ('us-cpi',        'US inflation (CPI)',     'inflation', '/api/v1/economy/cpi',          'oecd', '{}', 'US', 'united_states', 'monthly',   'percent', true,  10),
  ('de-cpi',        'Germany inflation (CPI)','inflation', '/api/v1/economy/cpi',          'oecd', '{}', 'DE', 'germany',       'monthly',   'percent', true,  11),
  ('jp-cpi',        'Japan inflation (CPI)',  'inflation', '/api/v1/economy/cpi',          'oecd', '{}', 'JP', 'japan',         'monthly',   'percent', true,  12),
  ('us-gdp-real',   'US real GDP',            'growth',    '/api/v1/economy/gdp/real',     'oecd', '{}', 'US', 'united_states', 'quarterly', 'index',   false, 20),
  ('us-unemployment','US unemployment rate',  'labour',    '/api/v1/economy/unemployment', 'oecd', '{}', 'US', 'united_states', 'monthly',   'percent', true,  30),
  ('us-yield-curve','US Treasury yield curve','rates',     '/api/v1/fixedincome/government/yield_curve', 'federal_reserve', '{}', 'US', null, 'daily', 'percent', true, 40),
  ('us-effr',       'US effective fed funds', 'rates',     '/api/v1/fixedincome/rate/effr','federal_reserve', '{}', 'US', null, 'daily', 'percent', true, 41),
  ('us-sofr',       'US SOFR',                'rates',     '/api/v1/fixedincome/rate/sofr','federal_reserve', '{}', 'US', null, 'daily', 'percent', true, 42),
  ('gold',          'Gold',                   'commodity', '/api/v1/derivatives/futures/historical', 'yfinance', '{"symbol":"GC=F"}', null, null, 'daily', 'usd', false, 50),
  ('oil-wti',       'Crude oil (WTI)',        'commodity', '/api/v1/derivatives/futures/historical', 'yfinance', '{"symbol":"CL=F"}', null, null, 'daily', 'usd', false, 51),
  ('btc',           'Bitcoin',                'crypto',    '/api/v1/crypto/price/historical',        'yfinance', '{"symbol":"BTC-USD"}', null, null, 'daily', 'usd', false, 60),
  ('sp500',         'S&P 500',                'index',     '/api/v1/index/price/historical',         'yfinance', '{"symbol":"^GSPC"}',   null, null, 'daily', 'index', false, 70)
-- `do update` on the DEFINITION (a redeploy should correct a route or a unit) but NOT on `enabled`:
-- disabling a series that has started failing is an operator decision, and a redeploy must not
-- silently re-enable it. Same discipline as the classification memberships.
on conflict (code) do update set
  name = excluded.name, category = excluded.category, route = excluded.route,
  provider = excluded.provider, params = excluded.params,
  country_iso2 = excluded.country_iso2, provider_country = excluded.provider_country,
  frequency = excluded.frequency, unit = excluded.unit,
  value_is_fraction = excluded.value_is_fraction, sort_order = excluded.sort_order;

-- ── serving view ─────────────────────────────────────────────────────────────────────────────
drop view if exists market.macro_current;

create view market.macro_current as
select distinct on (i.code, o.dimension)
  i.code,
  i.name,
  i.category,
  i.country_iso2,
  i.unit,
  i.frequency,
  o.dimension,
  -- SERVED IN THE UNIT THE READER EXPECTS. OECD returns inflation as a FRACTION (0.0239 = 2.39%)
  -- and the app wants percent; the flag lives on the series so no caller has to know which.
  case when i.value_is_fraction then round(o.value * 100, 4) else o.value end as value,
  o.as_of,
  o.fetched_at
from market.macro_indicator i
join market.macro_observation o on o.indicator_code = i.code
where i.enabled
order by i.code, o.dimension, o.as_of desc;

comment on view market.macro_current is
  'The latest value of every enabled macro series, already converted to its stated unit — OECD sends inflation as a fraction (0.0239) and the app wants percent, and that conversion belongs next to the series rather than in every reader.';

grant select on market.macro_indicator, market.macro_observation, market.macro_current
  to anon, authenticated, service_role;
grant insert, update, delete on market.macro_observation to service_role;
-- FULL write on the catalogue too, not just UPDATE. `every-table-is-reachable.sql` caught this:
-- it asserts service_role can read AND write every `market` table, because a table that is
-- created, applies cleanly and passes every functional check can still be unreachable in
-- production (migration 42 granted two views and forgot the table they read). A resource that
-- learns a new series — the way `data_source` rows are learned by the ingest — needs INSERT.
grant insert, update, delete on market.macro_indicator to service_role;

alter table market.macro_indicator  enable row level security;
alter table market.macro_observation enable row level security;
do $$ begin
  create policy macro_indicator_public_read on market.macro_indicator for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy macro_observation_public_read on market.macro_observation for select using (true);
exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
