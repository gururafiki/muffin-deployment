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
  ('9600003-0003','00000000-0000-0000-0000-000000009603', date '2024-03-01','10-K','sec-submissions',true)
on conflict do nothing;

do $$
declare
  companies int;
  first_form text;
  first_acc text;
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
end $$;

rollback;

\echo 'ok: the segment queue reaches every company before any company''s second filing'
