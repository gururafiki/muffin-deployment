-- Normalised securities reference model — IDEMPOTENT.
--
-- WHY THIS EXISTS
--   The stock universe was 35 hand-authored tickers (2–5 per sector, 26 of 35 American), which is
--   why a sector page shows a handful of names. Screeners cannot replace it: finviz's returns
--   MANGLED symbols (EEXFY for Expensify) and ignores its own country filter; yfinance's has no
--   country/sector. The universe instead comes from FUND HOLDINGS — SEC N-PORT filings, which are
--   public, keyless and carry name/LEI/CUSIP/ISIN/country/weight per holding.
--
-- NAMING: the new taxonomy tables are `taxonomy*`, NOT `classification_*`. The deployed
--   `market.classification_schemes/groups/members` already model MSCI/FTSE/World-Bank COUNTRY
--   membership and are live; a second set called `classification_scheme` (singular) beside them
--   would be a footgun. Geography keeps its existing home until the two are deliberately merged.
--
-- EVERY CATEGORICAL DIMENSION IS A TABLE, never free text and never a CHECK list — so tickers and
--   funds can be filtered and aggregated by joining keys instead of matching provider strings
--   ("Financial Services" vs "financials"). Lookup tables rather than Postgres ENUMs: an ENUM
--   needs ALTER TYPE (a migration + deploy) to add a value, cannot carry a display name/icon/sort
--   order, and is painful to rename. These are editable in Studio.

-- ═══════════════════════ 1. Lookup tables ═══════════════════════

create table if not exists market.security_type (
  code text primary key, name text not null, sort_order integer not null default 0
);
create table if not exists market.identifier_kind (
  code text primary key, name text not null,
  -- True when a value of this kind identifies exactly one security worldwide. Tickers do NOT
  -- (AAPL means different things on different exchanges), which is why they cannot be the key.
  is_global_unique boolean not null default true
);
create table if not exists market.currency (
  code text primary key, name text, symbol text
);
create table if not exists market.data_source (
  code text primary key, name text not null,
  -- Preference when two sources disagree; higher wins. Filings beat provider opinions.
  priority integer not null default 100
);
create table if not exists market.asset_category (   -- N-PORT assetCat
  code text primary key, name text not null
);
create table if not exists market.issuer_category (  -- N-PORT issuerCat
  code text primary key, name text not null
);

insert into market.security_type (code, name, sort_order) values
  ('equity','Equity',1), ('etf','ETF',2), ('fund','Fund',3), ('bond','Bond',4),
  ('cash','Cash',5), ('derivative','Derivative',6), ('commodity','Commodity',7),
  ('crypto','Crypto',8), ('other','Other',99)
on conflict (code) do update set name = excluded.name, sort_order = excluded.sort_order;

insert into market.identifier_kind (code, name, is_global_unique) values
  ('isin','ISIN',true), ('cusip','CUSIP',true), ('lei','LEI',true), ('figi','FIGI',true),
  ('cik','SEC CIK',true), ('ticker','Ticker',false)
on conflict (code) do update set name = excluded.name, is_global_unique = excluded.is_global_unique;

insert into market.data_source (code, name, priority) values
  ('sec-nport','SEC N-PORT filing',300), ('authored','Curated by hand',200),
  ('yfinance','yfinance',100), ('finviz','finviz',90), ('fmp','FMP',90)
on conflict (code) do update set name = excluded.name, priority = excluded.priority;

-- ═══════════════════════ 2. Issuer and security ═══════════════════════

create table if not exists market.issuer (
  issuer_id    uuid primary key default gen_random_uuid(),
  name         text not null,
  lei          text unique,
  cik          text unique,
  country_iso2 text references market.countries (iso2),
  created_at   timestamptz not null default now()
);

-- A surrogate key, deliberately: a symbol is not stable (renames, re-listings) and N-PORT
-- frequently identifies a holding with NO ticker at all.
create table if not exists market.security (
  security_id        uuid primary key default gen_random_uuid(),
  issuer_id          uuid references market.issuer (issuer_id) on delete set null,
  name               text not null,
  security_type_code text not null references market.security_type (code),
  currency_code      text references market.currency (code),
  country_iso2       text references market.countries (iso2),
  -- False for holdings with no resolvable ticker: they are still real positions and are kept,
  -- rather than dropped or given an invented symbol.
  is_tradeable       boolean not null default false,
  first_seen_at      timestamptz not null default now(),
  last_seen_at       timestamptz not null default now()
);
create index if not exists security_type_idx    on market.security (security_type_code);
create index if not exists security_country_idx on market.security (country_iso2);

-- THE load-bearing table. N-PORT gives ISIN/CUSIP/LEI; the app needs tickers; price data needs
-- PROVIDER tickers. Nothing joins without this. PK (kind, value) is what makes resolution
-- deterministic — one ISIN resolves to exactly one security.
create table if not exists market.security_identifier (
  kind_code   text not null references market.identifier_kind (code),
  value       text not null,
  security_id uuid not null references market.security (security_id) on delete cascade,
  source_code text references market.data_source (code),
  primary key (kind_code, value)
);
create index if not exists security_identifier_sec_idx on market.security_identifier (security_id);

-- Generalises the `instruments.price_symbol` special case (NESN -> NESN.SW on yfinance) from a
-- column into a row, so the next name that needs it costs nothing.
create table if not exists market.security_provider_symbol (
  security_id   uuid not null references market.security (security_id) on delete cascade,
  provider_code text not null references market.data_source (code),
  symbol        text not null,
  primary key (security_id, provider_code),
  unique (provider_code, symbol)
);

-- ═══════════════════════ 3. Taxonomy (sector / industry) ═══════════════════════

create table if not exists market.taxonomy (
  taxonomy_id text primary key,          -- 'gics' | 'yfinance' | 'finviz' | 'muffin'
  name        text not null,
  description text
);

create table if not exists market.taxonomy_node (
  node_id     uuid primary key default gen_random_uuid(),
  taxonomy_id text not null references market.taxonomy (taxonomy_id) on delete cascade,
  code        text not null,
  name        text not null,
  parent_id   uuid references market.taxonomy_node (node_id) on delete cascade,
  level       integer not null default 1,  -- 1 sector, 2 industry group, 3 industry, 4 sub-industry
  icon        text,                        -- muffin IconName, so the UI reads its label + glyph here
  sort_order  integer not null default 0,
  unique (taxonomy_id, code)
);
create index if not exists taxonomy_node_parent_idx on market.taxonomy_node (parent_id);

-- Many-to-many over time and over SOURCES: yfinance saying "Technology" and a filing saying
-- otherwise coexist, and a serving view picks by data_source.priority. Never overwrite — that is
-- the same rule already applied with instruments.provider_sector vs sector_id.
create table if not exists market.security_taxonomy (
  security_id uuid not null references market.security (security_id) on delete cascade,
  node_id     uuid not null references market.taxonomy_node (node_id) on delete cascade,
  source_code text not null references market.data_source (code),
  as_of       timestamptz not null default now(),
  primary key (security_id, node_id, source_code)
);
create index if not exists security_taxonomy_node_idx on market.security_taxonomy (node_id);

insert into market.taxonomy (taxonomy_id, name, description) values
  ('muffin','Muffin sectors','The curated sector buckets the app renders'),
  ('yfinance','yfinance','Provider taxonomy — sector + industry_category'),
  ('finviz','finviz','Provider taxonomy'),
  ('gics','GICS','Not populated: needs a licensed source')
on conflict (taxonomy_id) do update set name = excluded.name, description = excluded.description;

-- Seed the muffin sector nodes from the existing flat market.sectors so the new tree serves the
-- same 11 buckets from day one.
insert into market.taxonomy_node (taxonomy_id, code, name, level, icon, sort_order)
select 'muffin', s.id, s.name, 1, s.icon, s.sort_order from market.sectors s
on conflict (taxonomy_id, code) do update
  set name = excluded.name, icon = excluded.icon, sort_order = excluded.sort_order;

-- ═══════════════════════ 4. Fund holdings ═══════════════════════

-- A fund IS a security, so `fund_id` references the same table — which also means a fund can be
-- classified (XLK under Information Technology) and can itself be held by another fund.
create table if not exists market.fund_holding (
  fund_id              uuid not null references market.security (security_id) on delete cascade,
  security_id          uuid not null references market.security (security_id) on delete cascade,
  as_of                date not null,           -- the filing's report date
  weight               numeric,                 -- pctVal, as a percent
  balance              numeric,                 -- shares/units
  market_value         numeric,                 -- valUSD
  currency_code        text references market.currency (code),
  asset_category_code  text references market.asset_category (code),
  issuer_category_code text references market.issuer_category (code),
  source_code          text not null references market.data_source (code),
  primary key (fund_id, security_id, as_of)
);
create index if not exists fund_holding_security_idx on market.fund_holding (security_id);
create index if not exists fund_holding_asof_idx     on market.fund_holding (fund_id, as_of desc);

-- Latest filing per fund. Snapshots are never overwritten — the history is the point.
create or replace view market.fund_holding_current as
select h.*
from market.fund_holding h
join (select fund_id, max(as_of) as as_of from market.fund_holding group by fund_id) latest
  on latest.fund_id = h.fund_id and latest.as_of = h.as_of;

-- ═══════════════════════ 5. Control surface + bookkeeping ═══════════════════════

-- THE control surface. Adding an ETF must be a DATA change, not a migration + deploy: insert a
-- row here in Studio and the next run picks it up. `enabled = false` retires one without
-- destroying its holdings history.
create table if not exists market.tracked_fund (
  symbol           text primary key,
  name             text,
  kind             text,          -- 'country' | 'sector' | 'group' | 'other'
  enabled          boolean not null default true,
  -- Cached SEC lookups so the ticker -> filing walk is not repeated every run.
  cik              text,
  series_id        text,
  last_accession   text,
  last_report_date date,
  last_ingested_at timestamptz,
  notes            text,
  added_at         timestamptz not null default now()
);

create table if not exists market.ingest_run (
  run_id            uuid primary key default gen_random_uuid(),
  source_code       text references market.data_source (code),
  resource          text not null,
  scope             text,            -- e.g. the fund symbol, when scoped
  started_at        timestamptz not null default now(),
  finished_at       timestamptz,
  ok                boolean,
  securities_added  integer not null default 0,
  holdings_written  integer not null default 0,
  error             text
);
create index if not exists ingest_run_started_idx on market.ingest_run (started_at desc);

-- ═══════════════════════ 6. RLS ═══════════════════════
-- Same model as 09-market-rls.sql: reference data is public read, writes are service_role only
-- (which bypasses RLS). Operational tables get RLS with NO policy, which denies every other role.

do $$
declare t text;
begin
  foreach t in array array[
    'security_type','identifier_kind','currency','data_source','asset_category','issuer_category',
    'issuer','security','security_identifier','security_provider_symbol',
    'taxonomy','taxonomy_node','security_taxonomy','fund_holding','tracked_fund'
  ] loop
    execute format('alter table market.%I enable row level security', t);
    execute format($p$
      do $inner$ begin
        create policy %I on market.%I for select to public using (true);
      exception when duplicate_object then null; end $inner$;
    $p$, t || '_public_read', t);
    execute format('grant select on market.%I to anon, authenticated', t);
    execute format('grant select, insert, update, delete on market.%I to service_role', t);
  end loop;
end $$;

-- The ingest log is operational, not reference data: RLS on with no policy.
alter table market.ingest_run enable row level security;
grant select, insert, update, delete on market.ingest_run to service_role;

notify pgrst, 'reload schema';
