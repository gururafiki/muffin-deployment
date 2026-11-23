-- The repair of 2026-11-23 (migration 20261123100000) deletes the rows of every CNINFO report
-- stored two or more years before its filing year, re-queues it and its company's other full
-- reports, re-queues every full report read into no rows, and touches nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database matches nothing. Each fixture row is
-- kept out by exactly one clause:
--   re-queued, rows deleted:
--     cn-misdated    a FY2025 report (filed 2026-04) whose rows sit at 2024-12-31 (a lag of two,
--                    the smallest the repair takes)
--   re-queued, rows kept:
--     cn-sibling     the same company's FY2022 report (filed 2023-04), its rows rightly at 2022
--     cn-norows      another company's full report read into no rows
--   untouched:
--     cn-sib-summary the misdated company's summary (no table)
--     cn-right       another company's report one year behind its filing year
--     cn-queued      a misdated report already behind the parser (rows deleted, not counted)
--     sec-misdated   an SEC filing two years behind (another source)
--     cn-summary     a summary read into no rows (it carries no table)
--     cn-dual        a correct report of a company whose SEC filing holds a comparative year two
--                    years back (sec-dual). Only the selection's own source filter keeps that
--                    company out of `misdated`, and so this report from being re-queued.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('cninfo', 'CNINFO', 100), ('sec-segments', 'SEC segments', 100)
on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order) values
  ('revenue', 'Revenue', 'income', 'currency', true, false, 1)
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-00000000ce01', 'CE01 Misdated', 'equity'),
  ('00000000-0000-0000-0000-00000000ce02', 'CE02 Right', 'equity'),
  ('00000000-0000-0000-0000-00000000ce03', 'CE03 Queued', 'equity'),
  ('00000000-0000-0000-0000-00000000ce04', 'CE04 Dual', 'equity')
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, source_code, segments_parsed_at, segments_parser_version,
   report_type, report_date)
values
  ('00000000-0000-0000-0000-00000000ce01', 'cn-misdated.PDF', 'cninfo', '2026-11-20', 20, '年度报告', '2026-04-30'),
  ('00000000-0000-0000-0000-00000000ce01', 'cn-sibling.PDF', 'cninfo', '2026-11-20', 20, '年度报告', '2023-04-30'),
  ('00000000-0000-0000-0000-00000000ce01', 'cn-sib-summary.PDF', 'cninfo', '2026-11-20', 20, '年度报告摘要', '2026-04-30'),
  ('00000000-0000-0000-0000-00000000ce01', 'sec-misdated', 'sec-submissions', '2026-11-20', 20, '10-K', '2026-02-28'),
  ('00000000-0000-0000-0000-00000000ce02', 'cn-right.PDF', 'cninfo', '2026-11-20', 20, '年度报告', '2026-04-30'),
  ('00000000-0000-0000-0000-00000000ce02', 'cn-norows.PDF', 'cninfo', '2026-11-20', 20, '年度报告', '2025-04-30'),
  ('00000000-0000-0000-0000-00000000ce02', 'cn-summary.PDF', 'cninfo', '2026-11-20', 20, '年度报告摘要', '2025-04-30'),
  ('00000000-0000-0000-0000-00000000ce03', 'cn-queued.PDF', 'cninfo', '2026-11-20', 0, '年度报告', '2026-04-30'),
  ('00000000-0000-0000-0000-00000000ce04', 'cn-dual.PDF', 'cninfo', '2026-11-20', 20, '年度报告', '2026-04-30'),
  ('00000000-0000-0000-0000-00000000ce04', 'sec-dual', 'sec-submissions', '2026-11-20', 20, '20-F', '2026-03-31');

insert into market.security_segment
  (security_id, accession_number, axis, member_code, metric_code, period_type, period_start,
   period_ending, value, source_code, partition_id, reconciled_to)
select sid::uuid, acc, 'cninfo:分行业', member, 'revenue', 'annual',
       make_date(y, 1, 1), make_date(y, 12, 31), 1, src, 1, 1
  from (values
    ('00000000-0000-0000-0000-00000000ce01', 'cn-misdated.PDF', 'cninfo:煤炭', 2024, 'cninfo'),
    ('00000000-0000-0000-0000-00000000ce01', 'cn-sibling.PDF', 'cninfo:煤炭', 2022, 'cninfo'),
    ('00000000-0000-0000-0000-00000000ce01', 'sec-misdated', 'x:Coal', 2023, 'sec-segments'),
    ('00000000-0000-0000-0000-00000000ce02', 'cn-right.PDF', 'cninfo:电力', 2025, 'cninfo'),
    ('00000000-0000-0000-0000-00000000ce03', 'cn-queued.PDF', 'cninfo:钢铁', 2023, 'cninfo'),
    ('00000000-0000-0000-0000-00000000ce04', 'cn-dual.PDF', 'cninfo:电力', 2025, 'cninfo'),
    ('00000000-0000-0000-0000-00000000ce04', 'sec-dual', 'x:Power', 2023, 'sec-segments')
  ) v(sid, acc, member, y, src);

delete from market.one_shot where key = 'cninfo-older-and-misdated-2026-11-23';

\i stack/supabase/migrations/20261123100000_china_s_older_and_misdated_reports_are_read_again.sql

do $$
declare
  got text;
  want text := concat_ws(' | ', 'cn-dual.PDF v20', 'cn-misdated.PDF v0', 'cn-norows.PDF v0', 'cn-queued.PDF v0',
    'cn-right.PDF v20', 'cn-sib-summary.PDF v20', 'cn-sibling.PDF v0', 'cn-summary.PDF v20',
    'sec-dual v20', 'sec-misdated v20');
  rows_left text;
  rows_want text := concat_ws(' | ', 'cn-dual.PDF 2025', 'cn-right.PDF 2025',
    'cn-sibling.PDF 2022', 'sec-dual 2023', 'sec-misdated 2023');
begin
  select string_agg(format('%s v%s', accession_number, segments_parser_version), ' | '
                    order by accession_number)
    into got
    from market.security_filing
   where security_id in ('00000000-0000-0000-0000-00000000ce01',
                         '00000000-0000-0000-0000-00000000ce02',
                         '00000000-0000-0000-0000-00000000ce03',
                         '00000000-0000-0000-0000-00000000ce04');
  if got is distinct from want then
    raise exception E'the misdated re-queue moved the wrong reports:\n got  %\n want %', got, want;
  end if;
  select string_agg(format('%s %s', accession_number, extract(year from period_ending)), ' | '
                    order by accession_number)
    into rows_left
    from market.security_segment
   where security_id in ('00000000-0000-0000-0000-00000000ce01',
                         '00000000-0000-0000-0000-00000000ce02',
                         '00000000-0000-0000-0000-00000000ce03',
                         '00000000-0000-0000-0000-00000000ce04');
  if rows_left is distinct from rows_want then
    raise exception E'the misdated repair deleted the wrong rows:\n got  %\n want %',
      rows_left, rows_want;
  end if;
  if not exists (select 1 from market.one_shot
                  where key = 'cninfo-older-and-misdated-2026-11-23'
                    and reason like 'deleted 2 rows of misdated CNINFO reports; re-queued 1 '
                                    'misdated reports, 1 other full reports of their securities '
                                    'and 1 full reports read into no rows') then
    raise exception 'the repair did not record 2 rows deleted and 1 + 1 + 1 reports re-queued';
  end if;
end $$;

\echo ok china-s-older-and-misdated-reports-are-read-again
rollback;
