-- The venue directory asks OpenFIGI one question per (venue, type), plus questions filed under a
-- venue other than the one asked. Design: the umbrella's
-- docs/specs/2026-10-04-the-venue-directory-asks-by-query.md (approved 2026-10-04).
--
-- WHY. The sweep asked every venue for `securityType2: Common Stock` only, and OpenFIGI types REITs,
-- depositary receipts and partnerships apart from common stock. So none of them was in the
-- directory on any of the 59 venues: measured 2026-10-03, PLD, AMT, O, SPG, ET, EPD, MPLX, BIP,
-- TSM, BABA and NVO were all absent, against AAPL present. Separately, the US walk stops at
-- OpenFIGI's documented 15,000-result cap ("Max Results: 15,000", "Max Amount of Pages: 150",
-- results "listed alphabetically by FIGI"), so every US line newer than BBG013JYT8V4 is missing.
-- NYSE Arca (`UP`) lists every exchange-listed US stock in 5,541 lines, and each line's
-- `compositeFIGI` is its US line, which is how `US.arca` is filed under `US`.
--
-- THE QUESTIONS ARE ROWS, not code: lookups and editorial choices are control tables. A type is a
-- row in `directory_type` and applies to every enabled venue; a question asked of one code and
-- filed under another venue is a row in `directory_alias`. `directory_query` is their union, and
-- the Dagster sensor `new_exchange_sweeps` seeds one `exchange_sweep` partition per row, keyed
-- `query_key`. Adding Toronto's `Unit`, or splitting Frankfurt when it reaches the cap (14,205 lines
-- on 2026-09-27), is therefore a row, not a release.
--
-- SEEDS ARE `do nothing`: a Studio edit, such as disabling a type, must survive the next deploy,
-- which re-applies this file.

create table if not exists market.directory_type (
  security_type2 text primary key,
  key_suffix     text not null unique,
  enabled        boolean not null default true,
  notes          text,
  -- Lower-case letters only: the suffix becomes half of a Dagster partition key and of a raw file
  -- name, and `query_key` must stay one recognisable shape (`US.common`).
  constraint directory_type_key_suffix_shape check (key_suffix ~ '^[a-z]+$')
);

comment on table market.directory_type is
  'An OpenFIGI securityType2 the venue directory asks every enabled venue about. One row per type; '
  'key_suffix names the partition (US.common, US.reit). Read by the Dagster sensor new_exchange_sweeps '
  'through market.directory_query.';

create table if not exists market.directory_alias (
  query_key       text primary key,
  exch_code_asked text not null,
  files_under     text not null references market.exchange (exch_code),
  security_type2  text not null references market.directory_type (security_type2),
  enabled         boolean not null default true,
  reason          text not null,
  constraint directory_alias_query_key_shape check (query_key ~ '^[A-Z0-9]+\.[a-z]+$'),
  -- An alias that asked the venue it files under would be a second copy of a derived question.
  constraint directory_alias_asks_elsewhere check (exch_code_asked <> files_under)
);

comment on table market.directory_alias is
  'A venue-directory question asked of one OpenFIGI exchange code and filed under another venue: '
  'each line becomes its compositeFIGI line under files_under. US.arca asks UP (NYSE Arca) because '
  'the US composite walk stops at the 15,000-result cap.';

insert into market.directory_type (security_type2, key_suffix, notes) values
  ('Common Stock',       'common',      'The walk every venue has always had.'),
  ('REIT',               'reit',        'Typed apart from common stock. 2026-10-03: US 435 lines, LN 154, SP 39, CN 42.'),
  ('Depositary Receipt', 'dr',          'ADRs and GDRs. 2026-10-03: US 2,719 lines, LN 139.'),
  ('Partnership Shares', 'partnership', 'MLPs and limited partnerships. 2026-10-03: US 52 lines (AB, BIP, IEP).')
on conflict (security_type2) do nothing;

-- CONDITIONAL ON THE VENUE EXISTING. No migration seeds `market.exchange`: production's 59 rows
-- predate this migration set, and a database rebuilt from it has none, so an unconditional insert
-- would fail the foreign key there. Seeding control data for a rebuilt database is Stage 6.
insert into market.directory_alias (query_key, exch_code_asked, files_under, security_type2, reason)
select 'US.arca', 'UP', 'US', 'Common Stock',
       'The US composite walk stops at OpenFIGI''s 15,000-result cap, ordered by FIGI, so it misses '
       'every US listing since about 2022. NYSE Arca lists every exchange-listed US stock (5,541 lines, '
       '2026-10-03), and each line''s compositeFIGI is its US line.'
 where exists (select 1 from market.exchange where exch_code = 'US')
on conflict (query_key) do nothing;

create or replace view market.directory_query as
select e.exch_code || '.' || t.key_suffix as query_key,
       e.exch_code                        as exch_code_asked,
       e.exch_code                        as files_under,
       t.security_type2,
       false                              as maps_to_composite
  from market.exchange e
  cross join market.directory_type t
 where e.enabled and t.enabled
union all
select a.query_key,
       a.exch_code_asked,
       a.files_under,
       a.security_type2,
       true
  from market.directory_alias a
  join market.directory_type t on t.security_type2 = a.security_type2
  join market.exchange e on e.exch_code = a.files_under
 where a.enabled and t.enabled and e.enabled;

comment on view market.directory_query is
  'Every question the venue directory asks OpenFIGI: each enabled venue x enabled type, plus enabled '
  'aliases. One Dagster exchange_sweep partition per query_key. maps_to_composite means a line is '
  'filed as its compositeFIGI line under files_under.';

grant select, insert, update, delete on market.directory_type, market.directory_alias to service_role;
grant select on market.directory_type, market.directory_alias to ingest_rw, anon, authenticated;
grant select on market.directory_query to ingest_rw, service_role, anon, authenticated;

alter table market.directory_type enable row level security;
drop policy if exists directory_type_public_read on market.directory_type;
create policy directory_type_public_read on market.directory_type for select using (true);

alter table market.directory_alias enable row level security;
drop policy if exists directory_alias_public_read on market.directory_alias;
create policy directory_alias_public_read on market.directory_alias for select using (true);
