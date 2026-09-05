-- A KOREAN FILING IS NOT AN SEC FILING, AND THE FORM VOCABULARY IS WHAT SAYS SO.
--
-- WHY. `pending_segments` feeds `security-segments`, which addresses a filing as
-- `findInstanceUrl(cik, accession)` against EDGAR. Its only scope before this migration was
-- `security_disclosure.capability = 'held'` — and enabling DART makes every Korean security exactly
-- that, because a `security_filer` row is what `held` means. Korean filings would therefore enter
-- the SEC queue, where every one fails, at the HEAD of a breadth-first ordering.
--
-- THE FIXTURE IS HOSTILE ON PURPOSE: the Korean security carries a CIK. `s.cik is not null` is a
-- genuine precondition and it is NOT the thing that must exclude this row, so giving the Korean
-- company one makes the two candidate rules disagree — under `cik is not null` alone the filing
-- leaks, and only the regulator-keyed form clause keeps it out. Korean companies really do get
-- CIKs: KEPCO and POSCO both file 20-F.
--
-- AND THE KEY IS THE REGULATOR, NOT THE FILING'S OWN `source_code`. Measured 2026-09-05:
-- `security_filing.source_code` holds the RESOURCE that wrote the row (`sec-submissions` 984,
-- `sec-filings` 16) while `filing_form.source_code` holds the REGULATOR (`sec`). Two vocabularies
-- in one column name — scoping this view on `f.source_code = 'sec'` matches nothing and silently
-- empties the whole SEC backlog. The control below is what would catch that.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('KR','Korea, Republic of','KR',true),
  ('US','United States','US',true)
on conflict (iso2) do nothing;
-- `market.currency` is filled by the ingest at RUNTIME, so neither exists on a fresh database.
insert into market.currency (code) values ('KRW'), ('USD') on conflict do nothing;

-- Both regulators enabled, as production has them after this migration.
-- Both regulators enabled, as production has them after migration 172. `identifier_label` is NOT
-- NULL, and the rows already exist by the time any test runs — this is belt-and-braces so the file
-- is readable as a complete fixture, not a re-seed.
insert into market.disclosure_source (code, name, identifier_label, priority, enabled) values
  ('sec','SEC','CIK',100,true), ('dart','DART','corp_code',90,true)
on conflict (code) do update set enabled = excluded.enabled;
insert into market.disclosure_coverage (source_code, country_iso2) values ('dart','KR')
on conflict do nothing;
insert into market.filing_form (source_code, form_code, is_annual, carries_segments) values
  ('sec','10-K',true,true),
  ('sec','10-Q',false,true),
  ('dart','사업보고서',true,true)
on conflict (source_code, form_code) do update
  set is_annual = excluded.is_annual, carries_segments = excluded.carries_segments;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  -- The hostile row: Korean, and it HAS a CIK.
  ('00000000-0000-0000-0000-000000017201','T172 Hanguk Electronics','equity','KR','0000999901'),
  -- The control: an ordinary SEC filer, which must keep working.
  ('00000000-0000-0000-0000-000000017202','T172 Ordinary Inc','equity','US','0000999902')
on conflict do nothing;

-- A filer id is what makes capability 'held' — the state that used to be the only scope.
insert into market.security_filer (security_id, source_code, filer_id) values
  ('00000000-0000-0000-0000-000000017201','dart','00126380'),
  ('00000000-0000-0000-0000-000000017202','sec','0000999902')
on conflict do nothing;

insert into market.security_filing
  (security_id, accession_number, report_type, filing_date, source_code) values
  -- Two Korean annuals, so the breadth-first ordering has something to rank.
  ('00000000-0000-0000-0000-000000017201','20250311000123','사업보고서','2025-03-11','dart'),
  ('00000000-0000-0000-0000-000000017201','20240311000456','사업보고서','2024-03-11','dart'),
  -- The control's SEC filing. Note `sec-submissions`, which is what production actually stores —
  -- a view scoped on the filing's own source_code = 'sec' would drop this and pass every other
  -- assertion in this file.
  ('00000000-0000-0000-0000-000000017202','0000999902-25-000001','10-K','2025-02-01','sec-submissions')
on conflict do nothing;

do $$
declare
  kr_in_sec  int;
  sec_in_kr  int;
  kr_in_kr   int;
  sec_in_sec int;
  kr_round1  text;
begin
  -- 1. THE HEADLINE. A Korean filing must never reach the SEC queue, CIK or no CIK.
  select count(*) into kr_in_sec
    from market.pending_segments
   where security_id = '00000000-0000-0000-0000-000000017201';
  if kr_in_sec <> 0 then
    raise exception 'a Korean filing leaked into pending_segments: % rows (the SEC path would fetch it by CIK and fail on every one)', kr_in_sec;
  end if;

  -- 2. THE CONTROL, which is what stops the fix being "scope it to nothing". An over-tight filter
  --    — including the plausible-looking `f.source_code = ''sec''` — fails here.
  select count(*) into sec_in_sec
    from market.pending_segments
   where security_id = '00000000-0000-0000-0000-000000017202';
  if sec_in_sec <> 1 then
    raise exception 'an ordinary SEC filing must still be queued: expected 1, got %', sec_in_sec;
  end if;

  -- 3. The Korean backlog is satisfiable — a view nothing can ever return is the other failure.
  select count(*) into kr_in_kr
    from market.pending_kr_segments
   where security_id = '00000000-0000-0000-0000-000000017201';
  if kr_in_kr <> 2 then
    raise exception 'pending_kr_segments must offer both Korean annuals: expected 2, got %', kr_in_kr;
  end if;

  -- 4. And symmetrically, an SEC filing must not reach the DART fetcher.
  select count(*) into sec_in_kr
    from market.pending_kr_segments
   where security_id = '00000000-0000-0000-0000-000000017202';
  if sec_in_kr <> 0 then
    raise exception 'an SEC filing leaked into pending_kr_segments: % rows', sec_in_kr;
  end if;

  -- 5. BREADTH-FIRST. `round` is depth into a company's OWN history, so the newest annual is 1.
  --    Migration 156: ordering by fund weight alone parsed 14 companies out of 3,500, because
  --    weight belongs to the security and every filing of a company carries the same one.
  select accession_number into kr_round1
    from market.pending_kr_segments
   where security_id = '00000000-0000-0000-0000-000000017201' and round = 1;
  if kr_round1 is distinct from '20250311000123' then
    raise exception 'round 1 must be the NEWEST annual: expected 20250311000123, got %', coalesce(kr_round1,'<none>');
  end if;

  raise notice 'ok  a Korean filing is not an SEC filing (kr->sec 0, sec->sec 1, kr->kr 2, sec->kr 0, breadth-first)';
end $$;

rollback;
