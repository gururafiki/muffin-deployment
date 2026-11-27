-- Japan's annual reports are filed from EDINET's own catalogue, and the note reader's vocabulary is
-- a control table the worker cannot write (migration 20261127100000).
--
-- Filers and documents, and what `file_edinet_filings` must do:
--   E1 (Q1 registry, Q3 its second listing by issuer sibling):
--     S-A1  an annual report (120/010/030000)        -> filed for Q1 AND Q3
--     S-A2  an amended annual report (130)            -> never filed
--     S-A3  an annual report under the fund ordinance -> never filed
--     S-W1  withdrawn, already filed with a segment   -> its edinet rows removed; a CNINFO filing
--                                                         and segment under the same accession stay
--     S-W2  withdrawn, its type kept                   -> never filed
--   E2 (Q2, mapped only later):
--     S-B1  an annual report                          -> filed only once Q2 is mapped, and a call
--                                                         scoped to E2 leaves E1's rows alone

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('cninfo', 'CNINFO', 100)
  on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order) values
  ('revenue', 'Revenue', 'income', 'currency', true, false, 1)
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000027201', 'Q1', 'equity', null),
  ('00000000-0000-0000-0000-000000027202', 'Q2', 'equity', null),
  ('00000000-0000-0000-0000-000000027203', 'Q3', 'equity', null),
  ('00000000-0000-0000-0000-000000027204', 'R',  'equity', null);

insert into market.security_filer (security_id, source_code, filer_id, via) values
  ('00000000-0000-0000-0000-000000027201', 'edinet', 'E1', 'registry'),
  ('00000000-0000-0000-0000-000000027203', 'edinet', 'E1', 'issuer_sibling');

insert into market.edinet_document
  (doc_id, edinet_code, doc_type_code, ordinance_code, form_code, period_start, period_end,
   filed_on, withdrawn, xbrl, listed_on) values
  ('S-A1', 'E1', '120', '010', '030000', '2024-04-01', '2025-03-31', '2025-06-20', false, true,  '2025-06-20'),
  ('S-A2', 'E1', '130', '010', '030001', '2024-04-01', '2025-03-31', '2025-07-01', false, true,  '2025-07-01'),
  ('S-A3', 'E1', '120', '030', '030000', '2024-04-01', '2025-03-31', '2025-06-21', false, true,  '2025-06-21'),
  ('S-W1', 'E1', null,  null,  null,     null,         null,         '2024-06-20', true,  false, '2024-06-20'),
  ('S-W2', 'E1', '120', '010', '030000', '2023-04-01', '2024-03-31', '2024-06-21', true,  true,  '2024-06-21'),
  ('S-B1', 'E2', '120', '010', '030000', '2024-04-01', '2025-03-31', '2025-06-25', false, false, '2025-06-25');

-- S-W1 was filed and read before EDINET withdrew it; R holds a CNINFO filing under the same name.
insert into market.security_filing
  (security_id, accession_number, filing_date, report_date, report_type, source_code, is_xbrl) values
  ('00000000-0000-0000-0000-000000027201', 'S-W1', '2024-06-20', '2024-03-31', '有価証券報告書', 'edinet', true),
  ('00000000-0000-0000-0000-000000027204', 'S-W1', '2024-06-20', '2023-12-31', '年度报告', 'cninfo', false);
insert into market.security_segment
  (security_id, accession_number, axis, member_code, parent_axis, parent_member, metric_code,
   period_type, period_start, period_ending, value, source_code, partition_id, reconciled_to)
values
  ('00000000-0000-0000-0000-000000027201', 'S-W1', 'edinet:報告セグメント', 'edinet:A', null, null,
   'revenue', 'annual', '2023-04-01', '2024-03-31', 70, 'edinet', 1, 70),
  ('00000000-0000-0000-0000-000000027204', 'S-W1', 'cninfo:分行业', 'cninfo:A', null, null,
   'revenue', 'annual', '2023-01-01', '2023-12-31', 9, 'cninfo', 1, 9);

do $$
declare
  r record;
  got text;
begin
  select * into r from market.file_edinet_filings();
  if (r.filed, r.withdrawn_filings, r.withdrawn_segments) is distinct from (2, 1, 1) then
    raise exception 'first call filed %, removed % filings and % segments rather than 2, 1, 1',
      r.filed, r.withdrawn_filings, r.withdrawn_segments;
  end if;

  select string_agg(s.name || ':' || f.accession_number, ',' order by s.name, f.accession_number)
    into got
    from market.security_filing f join market.security s using (security_id)
   where f.source_code = 'edinet';
  if got is distinct from 'Q1:S-A1,Q3:S-A1' then
    raise exception 'edinet filings are %, expected Q1:S-A1,Q3:S-A1 (an amendment, a fund report, '
                    'an unmapped filer and a withdrawn report are never filed)', got;
  end if;

  if not exists (select 1 from market.security_filing
                  where accession_number = 'S-A1'
                    and security_id = '00000000-0000-0000-0000-000000027201'
                    and (filing_date, report_date, report_type, is_xbrl)
                        = ('2025-06-20'::date, '2025-03-31'::date, '有価証券報告書', true)) then
    raise exception 'S-A1 was not filed with its own date, period end, form and XBRL flag';
  end if;

  if (select count(*) from market.security_filing where accession_number = 'S-W1') <> 1
     or (select count(*) from market.security_segment where accession_number = 'S-W1') <> 1 then
    raise exception 'the withdrawn report''s removal reached a CNINFO row under the same accession';
  end if;

  -- A second call changes nothing.
  select * into r from market.file_edinet_filings();
  if (r.filed, r.withdrawn_filings, r.withdrawn_segments) is distinct from (0, 0, 0) then
    raise exception 'a second call filed %, removed % and % rather than nothing',
      r.filed, r.withdrawn_filings, r.withdrawn_segments;
  end if;

  -- Q2 is mapped later: a call scoped to E2 files its report and leaves E1's alone.
  update market.security_filing set filing_date = '2000-01-01'
   where accession_number = 'S-A1' and security_id = '00000000-0000-0000-0000-000000027201';
  insert into market.security_filer (security_id, source_code, filer_id, via)
  values ('00000000-0000-0000-0000-000000027202', 'edinet', 'E2', 'registry');
  select * into r from market.file_edinet_filings(array['E2']);
  if r.filed <> 1 then
    raise exception 'a call scoped to E2 filed % rather than 1', r.filed;
  end if;
  if (select filing_date from market.security_filing
       where accession_number = 'S-A1' and security_id = '00000000-0000-0000-0000-000000027201')
     <> '2000-01-01' then
    raise exception 'a call scoped to E2 rewrote E1''s filing';
  end if;
  select * into r from market.file_edinet_filings();
  if r.filed <> 1 then
    raise exception 'an unscoped call restored % filings rather than 1', r.filed;
  end if;
end $$;

-- The vocabulary: every label and concept role is structural or a metric that exists, and the
-- worker reads the rules and cannot write them.
do $$
declare
  bad text;
begin
  select string_agg(role, ', ') into bad
    from market.segment_note_rule
   where regulator = 'edinet' and rule in ('label', 'concept')
     and role not in ('total', 'adjustment', 'subtotal', 'subset', 'skip')
     and role not in (select code from market.metric);
  if bad is not null then
    raise exception 'segment_note_rule names roles that are no metric: %', bad;
  end if;
  if (select count(*) from market.segment_note_rule where regulator = 'edinet') < 20 then
    raise exception 'EDINET''s vocabulary is missing';
  end if;
  if not has_table_privilege('ingest_rw', 'market.segment_note_rule', 'select')
     or has_table_privilege('ingest_rw', 'market.segment_note_rule', 'insert')
     or has_table_privilege('ingest_rw', 'market.segment_note_rule', 'update') then
    raise exception 'ingest_rw must read segment_note_rule and never write it';
  end if;
  if not has_table_privilege('ingest_rw', 'market.edinet_document', 'insert')
     or not has_function_privilege('ingest_rw', 'market.file_edinet_filings(text[])', 'execute') then
    raise exception 'ingest_rw must write edinet_document and run file_edinet_filings';
  end if;
  if has_function_privilege('anon', 'market.file_edinet_filings(text[])', 'execute') then
    raise exception 'anon can run file_edinet_filings';
  end if;
end $$;

rollback;
