-- The CNINFO re-queue of 2026-11-16 (migration 20261116150000) puts every full PDF report read
-- without a row behind the parser, and touches nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database re-queues nothing, so applying the
-- migration set proves nothing about it. The fixture holds one row of each kind the rule must tell
-- apart:
--   * a full PDF report read with no row (Shenzhen's): re-queued (version 0), its read time kept;
--   * a full PDF report read with rows (Shanghai's mandated tables): untouched;
--   * a full PDF report already behind the parser: untouched, and not counted;
--   * a full PDF report never read: untouched (it is due already);
--   * a summary read with no row: untouched (the lane never reads one);
--   * a `.js` data file filed as a full report, marked read: untouched (the lane never reads one);
--   * a PDF another lane filed under the same type, read with no row: untouched, so the source
--     rule is load-bearing;
--   * a report whose row belongs to ANOTHER security under the same accession: re-queued, so the
--     row test is per security, as the segment key is.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('cninfo','CNINFO',100)
  on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('t-other-lane','Another lane',10)
  on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order)
  values ('revenue', 'Revenue', 'income', 'currency', true, false, 1) on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-00000000c5a1', 'C5A1 Shenzhen', 'equity'),
  ('00000000-0000-0000-0000-00000000c5a2', 'C5A2 Shanghai', 'equity'),
  ('00000000-0000-0000-0000-00000000c5a3', 'C5A3 Sibling', 'equity')
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, source_code, report_type, segments_parsed_at,
   segments_parser_version)
values
  ('00000000-0000-0000-0000-00000000c5a1', 'https://x/finalpage/2026-04-30/1.PDF', 'cninfo',
   '年度报告', timestamptz '2026-11-16', 20),
  ('00000000-0000-0000-0000-00000000c5a2', 'https://x/finalpage/2026-04-30/2.PDF', 'cninfo',
   '年度报告', timestamptz '2026-11-16', 20),
  ('00000000-0000-0000-0000-00000000c5a1', 'https://x/finalpage/2025-04-30/3.PDF', 'cninfo',
   '年度报告', timestamptz '2026-11-15', 0),
  ('00000000-0000-0000-0000-00000000c5a1', 'https://x/finalpage/2024-04-30/4.PDF', 'cninfo',
   '年度报告', null, null),
  ('00000000-0000-0000-0000-00000000c5a1', 'https://x/finalpage/2026-04-30/5.PDF', 'cninfo',
   '年度报告摘要', timestamptz '2026-11-16', 20),
  ('00000000-0000-0000-0000-00000000c5a1', 'https://x/finalpage/2020-04-30/c8.js', 'cninfo',
   '年度报告', timestamptz '2026-11-16', 20),
  ('00000000-0000-0000-0000-00000000c5a1', 'https://y/annual/2025.PDF', 't-other-lane',
   '年度报告', timestamptz '2026-11-16', 20),
  ('00000000-0000-0000-0000-00000000c5a1', 'https://x/finalpage/2026-04-30/7.PDF', 'cninfo',
   '年度报告', timestamptz '2026-11-16', 20),
  ('00000000-0000-0000-0000-00000000c5a3', 'https://x/finalpage/2026-04-30/7.PDF', 'cninfo',
   '年度报告', timestamptz '2026-11-16', 20);

insert into market.security_segment
  (security_id, accession_number, axis, member_code, metric_code, period_type, period_start,
   period_ending, value, source_code, partition_id)
values
  ('00000000-0000-0000-0000-00000000c5a2', 'https://x/finalpage/2026-04-30/2.PDF', 'cninfo:分行业',
   'cninfo:电力', 'revenue', 'annual', '2025-01-01', '2025-12-31', 1, 'cninfo', 1),
  ('00000000-0000-0000-0000-00000000c5a3', 'https://x/finalpage/2026-04-30/7.PDF', 'cninfo:分行业',
   'cninfo:电力', 'revenue', 'annual', '2025-01-01', '2025-12-31', 1, 'cninfo', 1);

delete from market.one_shot where key = 'cninfo-requeue-no-table-2026-11-16';

\i stack/supabase/migrations/20261116150000_china_s_reports_read_with_no_table_are_read_again.sql

do $$
declare
  got text;
  want text := concat_ws(' | ',
    'c5a1 https://x/finalpage/2020-04-30/c8.js read v20',
    'c5a1 https://x/finalpage/2024-04-30/4.PDF unread v-',
    'c5a1 https://x/finalpage/2025-04-30/3.PDF read v0',
    'c5a1 https://x/finalpage/2026-04-30/1.PDF read v0',
    'c5a1 https://x/finalpage/2026-04-30/5.PDF read v20',
    'c5a1 https://x/finalpage/2026-04-30/7.PDF read v0',
    'c5a1 https://y/annual/2025.PDF read v20',
    'c5a2 https://x/finalpage/2026-04-30/2.PDF read v20',
    'c5a3 https://x/finalpage/2026-04-30/7.PDF read v20');
begin
  select string_agg(
           concat_ws(' ', right(security_id::text, 4), accession_number,
                     case when segments_parsed_at is null then 'unread' else 'read' end,
                     'v' || coalesce(segments_parser_version::text, '-')),
           ' | ' order by security_id, accession_number)
    into got
    from market.security_filing
   where security_id::text like '00000000-0000-0000-0000-00000000c5a_';

  if got is distinct from want then
    raise exception E'the CNINFO re-queue touched the wrong rows\n got: %\nwant: %', got, want;
  end if;
  if not exists (select 1 from market.one_shot where key = 'cninfo-requeue-no-table-2026-11-16'
                   and reason like 're-queued 2 %') then
    raise exception 'the re-queue must record how many it re-queued, the already-queued excluded';
  end if;
  raise notice 'ok  only the full reports read with no row are behind the parser';
end $$;

-- ONE-SHOT: once the lane has read a report again (and found nothing), it is not re-queued.
update market.security_filing set segments_parser_version = 20
 where accession_number = 'https://x/finalpage/2026-04-30/1.PDF';

\i stack/supabase/migrations/20261116150000_china_s_reports_read_with_no_table_are_read_again.sql

do $$
begin
  if (select segments_parser_version from market.security_filing
       where accession_number = 'https://x/finalpage/2026-04-30/1.PDF') is distinct from 20 then
    raise exception 'the CNINFO re-queue ran twice; its key in market.one_shot is what stops that';
  end if;
  raise notice 'ok  the re-queue is one-shot';
end $$;

rollback;
