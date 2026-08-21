-- A 10-K AND AN 8-K ANSWER DIFFERENT QUESTIONS.
--
-- "What did the year look like" and "what just happened" are not the same request, and a single
-- date-ordered list buries the annual report under a month of press releases — a company files
-- dozens of 8-Ks a year and one 10-K.
--
-- The second thing pinned here is the FOREIGN vocabulary. A domestic registrant files 10-K/10-Q; a
-- foreign private issuer files 20-F/6-K instead and files neither of the first two. A `kind` rule
-- that only knew the domestic forms would label every foreign annual report an "event" — which is
-- exactly the shape of the three-value bug this codebase already recorded, where a binary
-- conditional over a three-value type type-checks and is wrong.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-filings','SEC filing index',245)
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Filingland','ZW',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000011701','T117 Domestic','equity','ZW','0000000117'),
  ('00000000-0000-0000-0000-000000011702','T117 Foreign','equity','ZW','0000000118'),
  ('00000000-0000-0000-0000-000000011703','T117 No CIK','equity','ZW', null)
on conflict (security_id) do nothing;

insert into market.security_filing
  (accession_number, security_id, filing_date, report_type, source_code) values
  ('acc-10k','00000000-0000-0000-0000-000000011701', current_date - 30, '10-K',    'sec-filings'),
  ('acc-10q','00000000-0000-0000-0000-000000011701', current_date - 10, '10-Q',    'sec-filings'),
  ('acc-8k1','00000000-0000-0000-0000-000000011701', current_date - 2,  '8-K',     'sec-filings'),
  ('acc-def','00000000-0000-0000-0000-000000011701', current_date - 5,  'DEF 14A', 'sec-filings'),
  -- The foreign vocabulary. Same company shape, different form names.
  ('acc-20f','00000000-0000-0000-0000-000000011702', current_date - 40, '20-F',    'sec-filings'),
  ('acc-6k', '00000000-0000-0000-0000-000000011702', current_date - 12, '6-K',     'sec-filings')
on conflict do nothing;

do $$
declare k text; n integer;
begin
  -- 1. THE DOMESTIC ANNUAL REPORT IS ANNUAL.
  select kind into k from market.security_recent_filings where accession_number = 'acc-10k';
  if k is distinct from 'annual' then raise exception '10-K is classified %, expected annual', k; end if;

  -- 2. AND SO IS THE FOREIGN ONE. A rule that only knew 10-K would call a 20-F an "event" and
  --    every foreign issuer would appear never to have filed an annual report.
  select kind into k from market.security_recent_filings where accession_number = 'acc-20f';
  if k is distinct from 'annual' then
    raise exception '20-F is classified %, expected annual — a foreign private issuer files this INSTEAD of a 10-K, not as well', k;
  end if;

  -- 3. THE INTERIM PAIR, both vocabularies.
  select kind into k from market.security_recent_filings where accession_number = 'acc-10q';
  if k is distinct from 'interim' then raise exception '10-Q is classified %, expected interim', k; end if;
  select kind into k from market.security_recent_filings where accession_number = 'acc-6k';
  if k is distinct from 'interim' then raise exception '6-K is classified %, expected interim', k; end if;

  -- 4. EVERYTHING ELSE IS AN EVENT — including the proxy, which is periodic in a calendar sense and
  --    is not a report on the business.
  select kind into k from market.security_recent_filings where accession_number = 'acc-8k1';
  if k is distinct from 'event' then raise exception '8-K is classified %, expected event', k; end if;
  select kind into k from market.security_recent_filings where accession_number = 'acc-def';
  if k is distinct from 'event' then raise exception 'DEF 14A is classified %, expected event', k; end if;

  -- 5. THE PERIODIC REPORTS ARE SEPARABLE. This is the whole point: two annual/interim filings
  --    against two events, and a caller must be able to ask for one without the other.
  select count(*) into n from market.security_recent_filings
   where security_id = '00000000-0000-0000-0000-000000011701' and kind <> 'event';
  if n <> 2 then
    raise exception 'the domestic filer has % periodic filings, expected 2 — a date-ordered list would bury the 10-K under its 8-Ks', n;
  end if;

  -- 6. THE CURSOR IS NOT A NEGATIVE CACHE, and a non-filer is never queued.
  update market.security set filings_fetched_at = now() - interval '8 days'
   where security_id = '00000000-0000-0000-0000-000000011701';
  select count(*) into n from market.pending_filings
   where security_id = '00000000-0000-0000-0000-000000011701';
  if n <> 1 then raise exception 'a filer read eight days ago is not queued — companies keep filing'; end if;

  select count(*) into n from market.pending_filings
   where security_id = '00000000-0000-0000-0000-000000011703';
  if n <> 0 then raise exception 'a security with no CIK is queued — the endpoint is asked BY cik'; end if;
end $$;

rollback;

\echo 'ok: a filing index separates reports from events'
