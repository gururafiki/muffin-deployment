-- Migration 49's backfill must type securities from the filing, and must NOT overreach.
--
-- WHY THIS EXISTS AS A TEST. The migration set applies cleanly against an EMPTY database, which
-- proves nothing here: the backfill only touches securities that have holdings, so on an empty
-- database its `update` matches zero rows and every guard inside it is unexercised. That is exactly
-- how migration 38 reached production — it passed on an empty database, then violated
-- `listing_one_primary_idx` against rows only production had, and left the stack without
-- `pending_prices`.
--
-- So this seeds the PRODUCTION SHAPE (securities typed `other` because the ingest read `units`
-- alone, with the filing's `assetCat` sitting unused on the holding) and asserts the three
-- behaviours the migration promises:
--
--   1. it reads the filing               DE -> derivative, DBT/ABS-MBS/LON -> bond, RA -> cash, EC -> equity
--   2. it only WIDENS from `other`       an `etf` or `equity` row keeps its deliberate type
--   3. it refuses to guess               a security two funds report under different categories is left alone
--
-- Run by the `migrations` job in quality.yml AFTER the two application passes.

\set ON_ERROR_STOP on

begin;

-- The lookup rows the ingest LEARNS at runtime; no migration seeds them, so a test that needs them
-- must create them itself.
insert into market.data_source (code, name) values ('sec', 'SEC') on conflict (code) do nothing;
insert into market.asset_category (code, name) values
  ('DE','DE'), ('DBT','DBT'), ('RA','RA'), ('EC','EC'), ('ABS-MBS','ABS-MBS'), ('LON','LON')
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-0000000049f1', 'T49 Fund A',    'etf'),
  ('00000000-0000-0000-0000-0000000049f2', 'T49 Fund B',    'etf'),
  -- The population the migration is for: everything non-share collapsed into one type.
  ('00000000-0000-0000-0000-0000000049a1', 'T49 Future',    'other'),
  ('00000000-0000-0000-0000-0000000049a2', 'T49 Govt Bond', 'other'),
  ('00000000-0000-0000-0000-0000000049a3', 'T49 Repo',      'other'),
  ('00000000-0000-0000-0000-0000000049a4', 'T49 Stock',     'other'),
  ('00000000-0000-0000-0000-0000000049a5', 'T49 MBS',       'other'),
  ('00000000-0000-0000-0000-0000000049a6', 'T49 Loan',      'other'),
  ('00000000-0000-0000-0000-0000000049a7', 'T49 Disputed',  'other'),
  -- Deliberately typed rows that must survive untouched.
  ('00000000-0000-0000-0000-0000000049b1', 'T49 Curated ETF',    'etf'),
  ('00000000-0000-0000-0000-0000000049b2', 'T49 Curated Equity', 'equity');

insert into market.fund_holding (fund_id, security_id, as_of, source_code, asset_category_code)
values
  ('00000000-0000-0000-0000-0000000049f1','00000000-0000-0000-0000-0000000049a1','2026-06-30','sec','DE'),
  ('00000000-0000-0000-0000-0000000049f1','00000000-0000-0000-0000-0000000049a2','2026-06-30','sec','DBT'),
  ('00000000-0000-0000-0000-0000000049f1','00000000-0000-0000-0000-0000000049a3','2026-06-30','sec','RA'),
  ('00000000-0000-0000-0000-0000000049f1','00000000-0000-0000-0000-0000000049a4','2026-06-30','sec','EC'),
  ('00000000-0000-0000-0000-0000000049f1','00000000-0000-0000-0000-0000000049a5','2026-06-30','sec','ABS-MBS'),
  ('00000000-0000-0000-0000-0000000049f1','00000000-0000-0000-0000-0000000049a6','2026-06-30','sec','LON'),
  -- A curated row is held by a fund too — this is what would overwrite it if the guard were missing.
  ('00000000-0000-0000-0000-0000000049f1','00000000-0000-0000-0000-0000000049b1','2026-06-30','sec','EC'),
  ('00000000-0000-0000-0000-0000000049f1','00000000-0000-0000-0000-0000000049b2','2026-06-30','sec','EC'),
  -- Two funds, two different answers.
  ('00000000-0000-0000-0000-0000000049f1','00000000-0000-0000-0000-0000000049a7','2026-06-30','sec','DBT'),
  ('00000000-0000-0000-0000-0000000049f2','00000000-0000-0000-0000-0000000049a7','2026-06-30','sec','EC');

-- Run the REAL migration against the rows just seeded. The seed has to happen first (the backfill
-- only touches securities that have holdings), and quality.yml applied the migrations before this
-- file ran, so the only way to exercise it is to invoke it again here. `\i` rather than a copy of
-- the `update`, so the test cannot drift away from what actually ships. The path is relative to the
-- repo root because that is where quality.yml runs psql from — and the migration is idempotent, so
-- applying it a third time is exactly what it is designed for.
\i stack/supabase/migrations/49-type-securities-from-the-filing.sql

do $$
declare
  bad text;
begin
  select string_agg(format('%s is %s, expected %s', s.name, s.security_type_code, e.want), '; ')
    into bad
  from market.security s
  join (values
    ('00000000-0000-0000-0000-0000000049a1'::uuid, 'derivative'),
    ('00000000-0000-0000-0000-0000000049a2'::uuid, 'bond'),
    ('00000000-0000-0000-0000-0000000049a3'::uuid, 'cash'),
    ('00000000-0000-0000-0000-0000000049a4'::uuid, 'equity'),
    ('00000000-0000-0000-0000-0000000049a5'::uuid, 'bond'),
    ('00000000-0000-0000-0000-0000000049a6'::uuid, 'bond'),
    -- Ambiguous: the migration must decline rather than pick.
    ('00000000-0000-0000-0000-0000000049a7'::uuid, 'other'),
    -- Deliberate types, untouched.
    ('00000000-0000-0000-0000-0000000049b1'::uuid, 'etf'),
    ('00000000-0000-0000-0000-0000000049b2'::uuid, 'equity')
  ) e(security_id, want) on e.security_id = s.security_id
  where s.security_type_code is distinct from e.want;

  if bad is not null then
    raise exception 'securities not typed from the filing: %', bad;
  end if;
  raise notice 'ok  securities are typed from the filing, and only where the filing agrees';
end $$;

rollback;
