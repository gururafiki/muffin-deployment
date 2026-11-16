-- The CNINFO re-queue (migration 20261115120000) puts every full PDF report the edge read behind the
-- parser, and touches nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database re-queues nothing, so applying the
-- migration set proves nothing about it. The fixture holds one row of each kind the rule must tell
-- apart:
--   * a full PDF report the edge read: re-queued (version 0), its read time kept;
--   * a summary and an English edition the edge also marked read: untouched;
--   * a `.js` data file filed as a full report, marked read: untouched (the lane never reads one);
--   * a full PDF report never read: untouched (it is due already);
--   * an SEC filing read at the current version: untouched;
--   * a PDF another lane filed under the same type: untouched. Without it the source rule is never
--     the only thing excluding a row, and a mutation dropping it passes clean (it did).

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('cninfo','CNINFO',100)
  on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('sec-submissions','SEC',250)
  on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('t-other-lane','Another lane',10)
  on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-00000000c4a1', 'C4A1 Yangtze', 'equity'),
  ('00000000-0000-0000-0000-00000000c4a2', 'C4A2 Filer', 'equity')
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, source_code, report_type, segments_parsed_at,
   segments_parser_version)
values
  ('00000000-0000-0000-0000-00000000c4a1', 'https://x/finalpage/2026-04-30/1.PDF', 'cninfo',
   '年度报告', timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-00000000c4a1', 'https://x/finalpage/2026-04-30/2.PDF', 'cninfo',
   '年度报告摘要', timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-00000000c4a1', 'https://x/finalpage/2026-04-30/3.PDF', 'cninfo',
   '年度报告（英文版）', timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-00000000c4a1', 'https://x/finalpage/2020-04-30/c4.js', 'cninfo',
   '年度报告', timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-00000000c4a1', 'https://x/finalpage/2025-04-29/5.PDF', 'cninfo',
   '年度报告', null, null),
  ('00000000-0000-0000-0000-00000000c4a2', '0000320193-26-000020', 'sec-submissions',
   '10-Q', timestamptz '2026-10-01', 20),
  ('00000000-0000-0000-0000-00000000c4a2', 'https://y/annual/2025.PDF', 't-other-lane',
   '年度报告', timestamptz '2026-10-01', 20);

delete from market.one_shot where key = 'cninfo-requeue-edge-reads-2026-11-15';

\i stack/supabase/migrations/20261115120000_the_china_segment_reader_leaves_the_edge.sql

do $$
declare
  got text;
  want text := concat_ws(' | ',
    '0000320193-26-000020 read v20',
    'https://x/finalpage/2020-04-30/c4.js read v20',
    'https://x/finalpage/2025-04-29/5.PDF unread v-',
    'https://x/finalpage/2026-04-30/1.PDF read v0',
    'https://x/finalpage/2026-04-30/2.PDF read v20',
    'https://x/finalpage/2026-04-30/3.PDF read v20',
    'https://y/annual/2025.PDF read v20');
begin
  select string_agg(
           concat_ws(' ', accession_number,
                     case when segments_parsed_at is null then 'unread' else 'read' end,
                     'v' || coalesce(segments_parser_version::text, '-')),
           ' | ' order by accession_number)
    into got
    from market.security_filing
   where security_id::text like '00000000-0000-0000-0000-00000000c4a_';

  if got is distinct from want then
    raise exception E'the CNINFO re-queue touched the wrong rows\n got: %\nwant: %', got, want;
  end if;
  raise notice 'ok  only the full PDF reports the edge read are behind the parser';
end $$;

-- ONE-SHOT: once the lane has read a report again, a second run must not re-queue it.
update market.security_filing set segments_parser_version = 20
 where accession_number = 'https://x/finalpage/2026-04-30/1.PDF';

\i stack/supabase/migrations/20261115120000_the_china_segment_reader_leaves_the_edge.sql

do $$
begin
  if (select segments_parser_version from market.security_filing
       where accession_number = 'https://x/finalpage/2026-04-30/1.PDF') is distinct from 20 then
    raise exception 'the CNINFO re-queue ran twice; its key in market.one_shot is what stops that';
  end if;
  raise notice 'ok  the re-queue is one-shot';
end $$;

rollback;
