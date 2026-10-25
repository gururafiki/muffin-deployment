-- A FISCAL PERIOD HAS A HOME. Phase 5 step 2a of the umbrella's docs/specs/2026-10-24-sec-family.md
-- (decisions 7 and 11).
--
-- Statements and metrics know only where a period ENDS, so a company that changed its fiscal year,
-- recast one, or reports 52/53-week years shows the same year twice. Measured: market-verify's
-- `check_one_period_one_point` carries `KNOWN_DRIFTED_PAIRS = 113`, annual pairs that are one year
-- under two dates. Company facts' `fy`/`fp` cannot fix it on their own: they label the FILING, so
-- AAPL's year ending 2022-09-24 carries fy 2022, 2023 and 2024 across three 10-Ks.
--
-- So the calendar is its own data, built by the SEC lane from each company's own annual reports and
-- by the Yahoo lane from stored period ends where SEC has nothing:
--   - `fiscal_calendar`: one row per REGIME, a span of years sharing one year-end rule. A change of
--     year end, or a successor company's calendar, starts a new regime;
--   - `fiscal_period`: one row per fiscal period per regime. Where two regimes' periods overlap
--     (Greif's recast year, Bristow's successor calendar), the NEWER regime's is canonical, and the
--     partial unique index allows one canonical period per (security, year, period).
-- `label_fiscal_periods` (next migration) labels statement rows from the canonical periods.
--
-- Both tables start empty; nothing reads them until the SEC lane writes calendars. Written by
-- `ingest_rw` (the Dagster worker), read by everyone.

create table if not exists market.fiscal_calendar (
  security_id     uuid not null references market.security (security_id) on delete cascade,
  regime          smallint not null check (regime >= 1),      -- 1 = the oldest
  source_code     text not null references market.data_source (code),
  year_end_month  smallint not null check (year_end_month between 1 and 12),
  year_end_day    smallint check (year_end_day between 1 and 31),  -- null for a 52/53-week regime
  is_52_53_week   boolean not null,
  week_end_isodow smallint check (week_end_isodow between 1 and 7), -- set only for 52/53-week
  first_year_end  date not null,
  last_year_end   date,                                        -- null = the current regime
  change_kind     text not null
                  check (change_kind in ('initial', 'year_end_change', 'successor', 'observed')),
  as_of           timestamptz not null default now(),
  primary key (security_id, regime),
  check (last_year_end is null or last_year_end >= first_year_end),
  check (is_52_53_week = (week_end_isodow is not null))
);
comment on table market.fiscal_calendar is
  'A company''s fiscal calendar, one row per regime (a span of years sharing one year-end rule). '
  'Built by the SEC lane from the company''s own annual reports, or by the Yahoo lane from stored '
  'period ends where SEC has none (source yfinance, change_kind observed).';

create table if not exists market.fiscal_period (
  security_id   uuid not null,
  regime        smallint not null,
  fiscal_year   smallint not null,
  fiscal_period text not null
                check (fiscal_period in ('FY', 'H1', 'H2', 'Q1', 'Q2', 'Q3', 'Q4', 'T')),
  period_start  date not null,
  period_end    date not null,
  is_canonical  boolean not null,      -- false where an overlapping newer-regime period supersedes it
  is_observed   boolean not null,      -- from a filing or a fact, rather than computed from the rule
  is_recast     boolean not null default false,
  source_code   text not null references market.data_source (code),
  as_of         timestamptz not null default now(),
  primary key (security_id, regime, fiscal_year, fiscal_period),
  foreign key (security_id, regime)
    references market.fiscal_calendar (security_id, regime) on delete cascade,
  check (period_end >= period_start)
);
comment on table market.fiscal_period is
  'One fiscal period of one calendar regime. A transition period is T. Where regimes overlap, the '
  'newer regime''s period is canonical (is_canonical) and the older one stays stored, out of series.';

create unique index if not exists fiscal_period_canonical
  on market.fiscal_period (security_id, fiscal_year, fiscal_period) where is_canonical;
create index if not exists fiscal_period_end
  on market.fiscal_period (security_id, period_end);

grant select on market.fiscal_calendar, market.fiscal_period to anon, authenticated;
grant select, insert, update, delete on market.fiscal_calendar, market.fiscal_period
  to service_role, ingest_rw;

alter table market.fiscal_calendar enable row level security;
alter table market.fiscal_period enable row level security;
drop policy if exists fiscal_calendar_public_read on market.fiscal_calendar;
create policy fiscal_calendar_public_read on market.fiscal_calendar for select using (true);
drop policy if exists fiscal_period_public_read on market.fiscal_period;
create policy fiscal_period_public_read on market.fiscal_period for select using (true);
