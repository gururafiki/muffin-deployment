-- A BACKLOG ORDERED BY A PROPERTY OF THE COMPANY PARSES ONE COMPANY.
--
-- WHY THIS IS A TEST. `pending_segments` shipped `order by best_weight desc, accession_number`.
-- Fund weight belongs to the SECURITY, so every filing of a company shares the sort key and the
-- accession tiebreak walks that company's whole history before the next company is reached.
-- Measured in production 2026-08-29: 440 filings parsed, belonging to **14 securities**
-- (69, 69, 69, 65, 61, 57, 39, 15, 10, 9, 9, 9, 8, 5 filings each) out of ~3,500 SEC filers.
-- Every signal said healthy — `written` 240-450 a run, `remaining` falling, `ok` true, and the
-- reconciliation guard passing, because the rows being written were CORRECT. They were the wrong
-- rows first, and the feature the table exists for (comparing one company's business line against
-- another's) was blocked on the ORDER rather than on data, a provider or a vocabulary.
--
-- THE FIXTURE MAKES THE TWO CANDIDATE RULES DISAGREE. Three companies with three filings each and
-- a page of THREE: ordering by weight returns three filings of the heaviest company, ordering by
-- round returns one filing from each. With a page equal to one company's history the two rules
-- give the same answer and the mutation passes clean.
--
-- It also pins ANNUALS BEFORE QUARTERLIES within a company: the heaviest company's most RECENT
-- filing is a 10-Q, so a rule ordering on `filing_date` alone would pick it, and
-- `security_segment_current` serves annual periods only.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZQ','Queueland','ZQ',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000009601', 'T96 Heavy',  'equity', 'ZQ', 9600001),
  ('00000000-0000-0000-0000-000000009602', 'T96 Middle', 'equity', 'ZQ', 9600002),
  ('00000000-0000-0000-0000-000000009603', 'T96 Light',  'equity', 'ZQ', 9600003)
on conflict (security_id) do nothing;

-- Three filings each, none parsed. The heavy company's newest document is a 10-Q filed AFTER its
-- 10-K, which is the ordinary shape of a filer's index and the reason the annual test bites.
insert into market.security_filing
  (accession_number, security_id, filing_date, report_type, source_code, is_xbrl) values
  ('9600001-0001','00000000-0000-0000-0000-000000009601', date '2026-05-01','10-Q','sec-submissions',true),
  ('9600001-0002','00000000-0000-0000-0000-000000009601', date '2026-02-01','10-K','sec-submissions',true),
  ('9600001-0003','00000000-0000-0000-0000-000000009601', date '2025-02-01','10-K','sec-submissions',true),
  ('9600002-0001','00000000-0000-0000-0000-000000009602', date '2026-04-01','10-K','sec-submissions',true),
  ('9600002-0002','00000000-0000-0000-0000-000000009602', date '2025-04-01','10-K','sec-submissions',true),
  ('9600002-0003','00000000-0000-0000-0000-000000009602', date '2024-04-01','10-K','sec-submissions',true),
  ('9600003-0001','00000000-0000-0000-0000-000000009603', date '2026-03-01','10-K','sec-submissions',true),
  ('9600003-0002','00000000-0000-0000-0000-000000009603', date '2025-03-01','10-K','sec-submissions',true),
  ('9600003-0003','00000000-0000-0000-0000-000000009603', date '2024-03-01','10-K','sec-submissions',true),
  -- AN EVENT, NOT ACCOUNTS. An 8-K has no row in `market.filing_form`, so it must never be queued
  -- — a company files dozens a year and they carry no audited segment note.
  ('9600003-0004','00000000-0000-0000-0000-000000009603', date '2026-06-01','8-K', 'sec-submissions',true)
on conflict do nothing;

do $$
declare
  companies int;
  first_form text;
  first_acc text;
  i int;
  pick_sid uuid;
  pick_acc text;
  seen uuid[] := '{}';
begin
  -- A page of three must span three companies. Under the shipped-then-fixed ordering it spans one.
  select count(distinct security_id) into companies
  from (select security_id from market.pending_segments
         where security_id in ('00000000-0000-0000-0000-000000009601',
                               '00000000-0000-0000-0000-000000009602',
                               '00000000-0000-0000-0000-000000009603')
         limit 3) page;
  if companies <> 3 then
    raise exception 'a page of 3 covers % companies rather than 3 — the queue is depth-first, so one filer consumes the budget and nothing can be compared across companies', companies;
  end if;

  -- Within a company, the ANNUAL report comes first even when a quarterly was filed later.
  select report_type, accession_number into first_form, first_acc
  from market.pending_segments
   where security_id = '00000000-0000-0000-0000-000000009601'
   order by round
   limit 1;
  if first_form <> '10-K' then
    raise exception 'the heaviest company''s first filing is a % (%) rather than its 10-K — security_segment_current serves annual periods, so a quarterly-first queue delivers nothing it can read', first_form, first_acc;
  end if;

  -- THE FORM VOCABULARY IS A CONTROL TABLE AND MUST BE LOAD-BEARING. Migration 163 created
  -- `market.filing_form` to retire the hardcoded `report_type in (...)` and left the list in
  -- place, so the table was read by NOTHING for a release — an unread table cannot be wrong, the
  -- same blind spot that left `exchange-listings` deployed and never scheduled.
  if exists (select 1 from market.pending_segments where accession_number = '9600003-0004') then
    raise exception 'an 8-K is queued for segment parsing — it has no row in market.filing_form, so the view is still carrying its own copy of the form list';
  end if;

  -- And turning a form OFF must remove its filings, or the table is decoration.
  update market.filing_form set carries_segments = false where form_code = '10-Q';
  if exists (select 1 from market.pending_segments where accession_number = '9600001-0001') then
    raise exception 'a 10-Q is still queued after filing_form.carries_segments was set false — the vocabulary is not being read';
  end if;
  update market.filing_form set carries_segments = true where form_code = '10-Q';

  -- And the round must be per COMPANY, not global: every company has a round 1.
  select count(*) into companies
  from market.pending_segments
   where round = 1
     and security_id in ('00000000-0000-0000-0000-000000009601',
                         '00000000-0000-0000-0000-000000009602',
                         '00000000-0000-0000-0000-000000009603');
  if companies <> 3 then
    raise exception '% of 3 companies have a round-1 filing — the row_number is not partitioned by security', companies;
  end if;

  -- ── ACROSS SUCCESSIVE PAGES, NOT JUST ONE ────────────────────────────────────────────────────
  -- Everything above inspects the queue at t=0, with nothing parsed — and the depth-first defect
  -- that has now reached production TWICE does not exist in that state. It appears as the queue
  -- DRAINS: if `round` is computed over only the OUTSTANDING filings, parsing a company's round 1
  -- renumbers its old round 2 to round 1, putting it back at the head where `best_weight` hands it
  -- the page again. Measured in production 2026-09-06 at parser version 20: **106 securities of
  -- 3,967** had had any filing re-read, median 15.5 each, one at **131 of its 164** — while every
  -- page-shaped assertion above passed.
  --
  -- This drives the loop the resource actually runs: a page of ONE, three times, marking each
  -- filing parsed exactly as the handler does. Three pages must touch three companies.
  --
  -- It runs LAST because it mutates the parse state the assertions above read.
  for i in 1..3 loop
    select security_id, accession_number into pick_sid, pick_acc
      from market.pending_segments
     where security_id in ('00000000-0000-0000-0000-000000009601',
                           '00000000-0000-0000-0000-000000009602',
                           '00000000-0000-0000-0000-000000009603')
     limit 1;
    exit when pick_sid is null;
    seen := seen || pick_sid;
    update market.security_filing
       set segments_parsed_at      = now(),
           segments_parser_version = (select version from market.segment_parser)
     where accession_number = pick_acc;
  end loop;

  select count(distinct x) into companies from unnest(seen) x;
  if companies <> 3 then
    raise exception 'three successive pages of one covered % companies rather than 3 (%) — `round` is being computed over the OUTSTANDING filings, so it renumbers as the queue drains and the heaviest company returns to the head after every parse', companies,
      (select string_agg(sec.name, ', ') from unnest(seen) x join market.security sec on sec.security_id = x);
  end if;
end $$;

rollback;

\echo 'ok: the segment queue reaches every company before any company''s second filing'
