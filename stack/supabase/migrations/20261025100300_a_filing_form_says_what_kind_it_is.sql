-- A FILING FORM SAYS WHAT KIND IT IS. Phase 5 step 2a of the umbrella's
-- docs/specs/2026-10-24-sec-family.md.
--
-- `market.filing_form` named only the four SEC forms whose instances the segments parser reads.
-- Every other rule about a form lived in a literal list somewhere else: the edge's
-- `ACCOUNTS_FORMS`, the `FORM_TYPES` it asks openbb for, and `security_recent_filings`' CASE, which
-- calls a 40-F or a 10-KT an "event" because nobody added them to it. The SEC lane reads the forms
-- from this table instead:
--   - `kind`: accounts, event, proxy or notice;
--   - `is_amendment`, `is_transition` (10-KT, 10-QT);
--   - `kept`: the filings writer stores it (a form with no row here is not stored);
--   - `refreshes_facts`: a new filing of it changes the company's XBRL facts, so its company facts
--     are fetched again.
--
-- THE SEC SEEDS ARE PRODUCTION'S OWN REPORT TYPES, measured 2026-10-24 (`select report_type,
-- count(*) from market.security_filing`): 10-Q 164,440; 8-K 85,819; 10-K 51,931; 6-K 17,695;
-- 20-F 5,336; 8-K/A 1,770; 40-F 1,345; 10-K/A 501; 10-Q/A 188; NT 10-Q 173; NT 10-K 152;
-- 6-K/A 126; 20-F/A 52; 8-K12B 30; NT 20-F 13; 10-KT 10; 8-K12G3 7; 8-K12B/A 4; NT 10-K/A 3;
-- 10-QT 2. Plus 40-F/A and 10-KT/A, the amendments of forms held, and DEF 14A, which the edge asks
-- openbb for.
--
-- 6-K IS ACCOUNTS, NOT AN EVENT. A foreign private issuer files 20-F and 6-K INSTEAD of 10-K and
-- 10-Q (BABA: twelve 6-Ks and no 10-Q), and `security_recent_filings` already shows it as the
-- interim. It does not refresh facts: a 6-K carries no XBRL financial statements.
--
-- `carries_segments` STAYS TRUE ON EXACTLY 10-K, 10-Q, 20-F AND 40-F, so `pending_segments`, which
-- the edge segments handler reads until Phase 6, is unchanged. Every new row is seeded false.
--
-- The worker only READS this table, so `ingest_rw`'s default DML on `market` is revoked (the same
-- rule as `directory_type`: the worker may not rewrite its own instructions).
--
-- Guard: stack/supabase/tests/a-filing-form-says-what-kind-it-is.sql.

alter table market.filing_form
  add column if not exists kind text not null default 'accounts',
  add column if not exists is_amendment boolean not null default false,
  add column if not exists is_transition boolean not null default false,
  add column if not exists kept boolean not null default true,
  add column if not exists refreshes_facts boolean not null default false;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'filing_form_kind_check') then
    alter table market.filing_form
      add constraint filing_form_kind_check
      check (kind in ('accounts', 'event', 'proxy', 'notice'));
  end if;
end $$;

comment on column market.filing_form.kind is
  'accounts (a report of the company''s results), event, proxy or notice.';
comment on column market.filing_form.kept is
  'The filings writer stores filings of this form. A form with no row is not stored.';
comment on column market.filing_form.refreshes_facts is
  'A new filing of this form changes the filer''s XBRL company facts, so they are fetched again.';

-- The four forms already here hold the company's XBRL facts.
update market.filing_form
   set refreshes_facts = true
 where source_code = 'sec' and form_code in ('10-K', '10-Q', '20-F', '40-F')
   and not refreshes_facts;

insert into market.filing_form
  (source_code, form_code, is_annual, carries_segments, kind, is_amendment, is_transition, kept,
   refreshes_facts)
values
  ('sec', '10-K/A',   true,  false, 'accounts', true,  false, true, true),
  ('sec', '10-Q/A',   false, false, 'accounts', true,  false, true, true),
  ('sec', '20-F/A',   true,  false, 'accounts', true,  false, true, true),
  ('sec', '40-F/A',   true,  false, 'accounts', true,  false, true, true),
  ('sec', '10-KT',    true,  false, 'accounts', false, true,  true, true),
  ('sec', '10-KT/A',  true,  false, 'accounts', true,  true,  true, true),
  ('sec', '10-QT',    false, false, 'accounts', false, true,  true, true),
  ('sec', '6-K',      false, false, 'accounts', false, false, true, false),
  ('sec', '6-K/A',    false, false, 'accounts', true,  false, true, false),
  ('sec', '8-K',      false, false, 'event',    false, false, true, false),
  ('sec', '8-K/A',    false, false, 'event',    true,  false, true, false),
  ('sec', '8-K12B',   false, false, 'event',    false, false, true, false),
  ('sec', '8-K12B/A', false, false, 'event',    true,  false, true, false),
  ('sec', '8-K12G3',  false, false, 'event',    false, false, true, false),
  ('sec', 'DEF 14A',  false, false, 'proxy',    false, false, true, false),
  ('sec', 'NT 10-K',  false, false, 'notice',   false, false, true, false),
  ('sec', 'NT 10-K/A',false, false, 'notice',   true,  false, true, false),
  ('sec', 'NT 10-Q',  false, false, 'notice',   false, false, true, false),
  ('sec', 'NT 20-F',  false, false, 'notice',   false, false, true, false)
on conflict (source_code, form_code) do nothing;

revoke insert, update, delete on market.filing_form from ingest_rw;
