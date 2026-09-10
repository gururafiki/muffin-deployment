-- Phase 2 (D1): the normalised price model, created BESIDE the tables it replaces.
--
-- Nothing here is read by anything yet. `market.security_price`, `market.prices` and
-- `market.performance` keep serving the app until the Dagster lanes have run a dual-run parity soak;
-- this migration only makes the destination exist so the build-out costs no further deploys. Design:
-- docs/superpowers/specs/2026-09-10-prices-dagster-design.md in the umbrella.
--
-- WHAT IS BEING NORMALISED, AND WHAT EACH ONE COST BEFORE:
--
--   * `security_price(security_id, date, close, GRAIN)` put a SAMPLING concept in the primary key,
--     so one date carried two rows meaning different things — a daily observation and a weekly
--     downsample — and every reader had to know which it wanted. `price_bar` holds observations
--     only; weekly becomes a matview, which is what retires `security-price-history` entirely: with
--     full daily history held, a weekly series is arithmetic rather than a second fetch.
--
--   * `market.prices(SYMBOL, date, close)` held the same fact under a second key, foreign-keyed to
--     the curated instruments, which is why a universe-wide write into it was refused and
--     `security_price` had to exist at all. One fact, one key.
--
--   * `performance(scope, SCOPE_ID, period, …)` had a polymorphic key: `scope_id` is a symbol for an
--     instrument, an ISO-2 code for a country and a scheme-prefixed string for a group, with no
--     referential integrity to any of them. Measured: 81,698 instrument rows, 405 country, 153
--     group, 77 sector. It splits into `security_return` (keyed on `security_id`, so a symbol
--     change cannot orphan it — migration 39 had to re-key it by hand once) and `index_return`
--     (keyed on a real dimension row).
--
--   * `period` was a ten-value CHECK constraint repeated in the table definition. It is a dimension.
--
-- The four ingestion-state columns on `market.security` (`prices_missing_at`,
-- `price_history_missing_at`, `price_history_from`, `performance_missing_at`) are NOT dropped here:
-- the old resources still read them. They go with the retirement migration, once the ledger owns
-- that state.

-- ---------------------------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------------------------

create table if not exists market.return_period (
  period_code   text primary key,
  lookback_days integer,
  label         text    not null,
  sort_order    integer not null
);

comment on table market.return_period is
  'The return windows this pipeline computes. A DIMENSION rather than the CHECK constraint it '
  'replaces, so adding a window is a row and a reader can join for the label and the ordering '
  'instead of hard-coding ten strings.';
comment on column market.return_period.lookback_days is
  'Calendar days back from today for the anchor bar. NULL where the anchor is not a lookback at '
  'all: `1d` anchors on the PREVIOUS BAR (a date lookback resolves a weekend or holiday to the '
  'same bar and reports a flat 0.00%), and `ytd` anchors on the last close of last year (so early '
  'January is measured from the true year-end rather than from the first bar of the new year).';

insert into market.return_period (period_code, lookback_days, label, sort_order) values
  ('1d',   null, '1 day',    10),
  ('1w',      7, '1 week',   20),
  ('1m',     30, '1 month',  30),
  ('3m',     91, '3 months', 40),
  ('6m',    182, '6 months', 50),
  ('ytd',  null, 'Year to date', 60),
  ('1y',    365, '1 year',   70),
  ('3y',   1095, '3 years',  80),
  ('5y',   1826, '5 years',  90),
  ('10y',  3652, '10 years', 100)
on conflict (period_code) do nothing;

create table if not exists market.index_scope_kind (
  code  text primary key,
  label text not null
);

comment on table market.index_scope_kind is
  'What kind of thing an index-like scope is. Three values today, and a table rather than a CHECK '
  'because a binary conditional over a three-value type is a bug that type-checks — this schema '
  'shipped one, labelling every frontier market "Emerging market".';

insert into market.index_scope_kind (code, label) values
  ('sector',  'Sector'),
  ('country', 'Country'),
  ('group',   'Classification group')
on conflict (code) do nothing;

-- The subject of a return that is NOT a security. Replaces the `scope`/`scope_id` pair, which was a
-- polymorphic key with no referential integrity: `scope_id` could be an ISO-2 code, a sector slug or
-- `msci:na`, and nothing could tell you which without reading `scope` first.
create table if not exists market.index_scope (
  index_code   text primary key,
  scope_kind   text not null references market.index_scope_kind,
  label        text not null,
  country_iso2 text references market.countries,
  proxy_symbol text,
  source_code  text references market.data_source,
  enabled      boolean not null default true
);

comment on column market.index_scope.proxy_symbol is
  'The ETF or provider group this scope is MEASURED FROM, when it is measured rather than computed '
  '— country returns come from a country ETF''s bars, sector returns from finviz''s own groups. '
  'NULL means the number is computed from constituents. Stored because "which symbol produced this '
  'number" is otherwise unanswerable, and one dead symbol (FM, liquidated 2025) once returned a '
  'bare 502 for a whole scope.';
comment on column market.index_scope.country_iso2 is
  'Set only for `country` scopes, and a real foreign key — the ISO-2 code used to be free text in '
  '`performance.scope_id`. A subtype column: NULL for sectors and groups, which have no country.';

-- DERIVED FROM WHAT THE PIPELINE ALREADY PRODUCES, not authored. Reference data typed from memory
-- is how Taiwan was silently dropped from the country list once. On a fresh database
-- `market.performance` is empty and this seeds nothing, which is correct: the scopes are whatever
-- the running system has been measuring, and the assets re-assert them.
insert into market.index_scope (index_code, scope_kind, label, country_iso2, source_code)
select p.scope || ':' || p.scope_id,
       p.scope,
       coalesce(c.name, p.scope_id),
       case when p.scope = 'country' then c.iso2 end,
       min(p.source)
  from market.performance p
  left join market.countries c on p.scope = 'country' and c.iso2 = p.scope_id
 where p.scope <> 'instrument'
 group by 1, 2, 3, 4
on conflict (index_code) do nothing;

-- ---------------------------------------------------------------------------------------------
-- Facts
-- ---------------------------------------------------------------------------------------------

-- ONE ROW PER OBSERVATION. No `grain`: a weekly series is a downsample of this and lives in a
-- matview, so the two can never disagree about what a company's close was.
--
-- PARTITIONED BY YEAR. ~88 M rows are expected at full depth (12,016 securities x a measured mean
-- of ~7,300 bars), so a chart's date filter prunes, `vacuum` runs per year, and a retention
-- decision later is a `detach` rather than a table rewrite.
create table if not exists market.price_bar (
  security_id   uuid    not null references market.security on delete cascade,
  trade_date    date    not null,
  close         numeric not null constraint price_bar_close_positive check (close > 0),
  volume        bigint,
  currency_code text references market.currency,
  source_code   text    not null references market.data_source,
  primary key (security_id, trade_date)
) partition by range (trade_date);

comment on table market.price_bar is
  'Daily closes for the whole universe, keyed on the security so a symbol change cannot orphan a '
  'series — measured 2026-08-12, migration 39 changed the display symbol for 41% of sampled non-US '
  'securities and everything keyed on it needed re-keying by hand. Replaces market.security_price '
  '(which mixed a 400-day daily window with a 20-year weekly one under a `grain` column) and '
  'market.prices (the same fact keyed on a symbol).';

comment on column market.price_bar.currency_code is
  'NULLABLE, AND THAT IS MEASURED RATHER THAN LAZY. 10,469 of 10,894 askable equities (96.1%) have '
  'a currency from their listing or from `security.currency_code`; 425 have neither. NOT NULL would '
  'refuse those securities a price row at all, which is worse than the bug it prevents: the app '
  'already WITHHOLDS a label it cannot justify (that is how the CNY-rendered-as-"$1.02T" defect was '
  'fixed), so an unlabelled number degrades gracefully while a missing bar means no chart. The '
  'shortfall is a symbol-resolution gap and belongs to the universe family; an asset check counts '
  'it so it stays visible instead of becoming normal.';

comment on column market.price_bar.close is
  'Split- and dividend-adjusted as the provider supplies it. A non-positive close is REFUSED here '
  'rather than filtered downstream: a zero latest close yields -100% on every period, which was a '
  '1,078-row defect, and the constraint is cheaper than remembering.';

-- Yearly partitions. 1970 because the deep fetch asks from 1970-01-01 — a FIXED literal, since
-- every provider call is keyed by URI in http-cache and a start date derived from now() mints a new
-- cache entry per run. 2030 gives five years of headroom; extending is one `create table`.
--
-- NO DEFAULT PARTITION, DELIBERATELY. It would silently accept a bar outside the range, and
-- attaching a real partition later then has to scan it. A date outside 1970..2030 is a parsing bug
-- and should fail loudly at the insert.
do $$
declare y integer;
begin
  for y in 1970..2030 loop
    execute format(
      'create table if not exists market.price_bar_%s partition of market.price_bar '
      'for values from (%L) to (%L)',
      y, make_date(y, 1, 1), make_date(y + 1, 1, 1));
  end loop;
end $$;

create table if not exists market.security_return (
  security_id      uuid    not null references market.security on delete cascade,
  period_code      text    not null references market.return_period,
  as_of            date    not null,
  price_return_pct numeric,
  total_return_pct numeric,
  source_code      text    not null references market.data_source,
  primary key (security_id, period_code)
);

comment on column market.security_return.total_return_pct is
  'Daily-reinvested TOTAL return for the period, in percent. NULL means NOT COMPUTED — no dividend '
  'data, or a series ineligible for the window — and must never be coalesced to price_return_pct, '
  'which would erase the difference between "paid no income" and "we do not know".';
comment on column market.security_return.price_return_pct is
  'Price return in percent. A period is OMITTED rather than reported when its anchor predates a '
  'discontinuity (a redenomination or an unadjusted ratio change), when the series is stale, or '
  'when the window never moved — a flat window is a series that is not being priced, not a 0.00% '
  'return, and 62 identical consecutive closes is what proved it.';

create table if not exists market.index_return (
  index_code       text    not null references market.index_scope,
  period_code      text    not null references market.return_period,
  as_of            date    not null,
  price_return_pct numeric,
  total_return_pct numeric,
  source_code      text    not null references market.data_source,
  primary key (index_code, period_code)
);

comment on table market.index_return is
  'Returns for sector, country and classification-group scopes. Separate from security_return '
  'because the subjects are different entities with different keys — merging them is what made '
  '`performance.scope_id` polymorphic and unjoinable.';

-- ---------------------------------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------------------------------
--
-- GRANTED ON THE PARTITIONED PARENT ONLY. Proven on the node 2026-09-10 inside a rolled-back
-- transaction: with `grant select, insert` on the parent alone, a role inserts and selects through
-- it perfectly, while `has_table_privilege(role, '<partition>', 'SELECT')` reads FALSE — a
-- partition's own ACL is never consulted when the query names the parent. Granting all 61 would be
-- 61 things to keep in step for no behaviour.
grant select, insert, update, delete on
  market.price_bar, market.security_return, market.index_return,
  market.index_scope, market.index_scope_kind, market.return_period
  to service_role, ingest_rw;

grant select on
  market.price_bar, market.security_return, market.index_return,
  market.index_scope, market.index_scope_kind, market.return_period
  to anon, authenticated;

-- RLS with an EXPLICIT POLICY, not grants alone — the convention every other `market` table
-- follows. Grants alone were restrictive but left `rls_disabled_in_public` on the advisor and were
-- one stray `grant` away from being wrong.
alter table market.price_bar        enable row level security;
alter table market.security_return  enable row level security;
alter table market.index_return     enable row level security;
alter table market.index_scope      enable row level security;
alter table market.index_scope_kind enable row level security;
alter table market.return_period    enable row level security;

create policy price_bar_public_read        on market.price_bar        for select using (true);
create policy security_return_public_read  on market.security_return  for select using (true);
create policy index_return_public_read     on market.index_return     for select using (true);
create policy index_scope_public_read      on market.index_scope      for select using (true);
create policy index_scope_kind_public_read on market.index_scope_kind for select using (true);
create policy return_period_public_read    on market.return_period    for select using (true);
