-- The repair of 2026-11-23 (migration 20261125120000) re-queues every CNINFO report holding a placed
-- revenue split under 10 m yuan, and every one dated after its own publication, and nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database matches nothing. Each fixture row is
-- kept out by exactly one clause:
--   re-queued:
--     cu-tiny       a placed, top-level, annual revenue split of 122,294 yuan
--     cu-future     a report filed 2012-03-15 whose rows sit at 2079-12-31
--   untouched:
--     cu-right      a split of 1.2 bn yuan
--     cu-unplaced   a tiny revenue member that is not placed (partition 0), though it carries a
--                   target, so the partition clause is the only one keeping it out
--     cu-nested     a tiny cell under a parent (it reconciles to its parent, not the company)
--     cu-cost       a tiny cost split (the rule reads revenue)
--     cu-quarter    a tiny quarterly split
--     sec-tiny      an SEC filing with a tiny split (another source)
--     cu-queued     a tiny split already behind the parser (not counted)

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('cninfo', 'CNINFO', 100), ('sec-segments', 'SEC segments', 100)
on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order) values
  ('revenue', 'Revenue', 'income', 'currency', true, false, 1),
  ('cost_of_revenue', 'Cost of revenue', 'income', 'currency', true, false, 2)
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-0000000c0f01', 'CU01', 'equity')
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, source_code, segments_parsed_at, segments_parser_version,
   report_type, report_date)
select '00000000-0000-0000-0000-0000000c0f01', acc, src, '2026-11-20', v, rt, d::date
  from (values
    ('cu-tiny.PDF', 'cninfo', 20, '年度报告', '2026-04-30'),
    ('cu-future.PDF', 'cninfo', 20, '年度报告', '2012-03-15'),
    ('cu-right.PDF', 'cninfo', 20, '年度报告', '2025-04-30'),
    ('cu-unplaced.PDF', 'cninfo', 20, '年度报告', '2024-04-30'),
    ('cu-nested.PDF', 'cninfo', 20, '年度报告', '2023-04-30'),
    ('cu-cost.PDF', 'cninfo', 20, '年度报告', '2022-04-30'),
    ('cu-quarter.PDF', 'cninfo', 20, '年度报告', '2021-04-30'),
    ('sec-tiny', 'sec-submissions', 20, '10-K', '2020-02-28'),
    ('cu-queued.PDF', 'cninfo', 0, '年度报告', '2019-04-30')
  ) v(acc, src, v, rt, d);

insert into market.security_segment
  (security_id, accession_number, axis, member_code, parent_member, metric_code, period_type,
   period_start, period_ending, value, source_code, partition_id, reconciled_to)
select '00000000-0000-0000-0000-0000000c0f01', acc, axis, member, parent, metric, pt,
       make_date(y, 1, 1), make_date(y, 12, 31), val, src, part, target
  from (values
    ('cu-tiny.PDF', 'cninfo:分行业', 'cninfo:军工电子', null, 'revenue', 'annual', 2025, 122294.31, 'cninfo', 1, 122294.31),
    ('cu-future.PDF', 'cninfo:分行业', 'cninfo:电力', null, 'revenue', 'annual', 2079, 9e9, 'cninfo', 1, 9e9),
    ('cu-right.PDF', 'cninfo:分行业', 'cninfo:电力', null, 'revenue', 'annual', 2024, 1.2e9, 'cninfo', 1, 1.2e9),
    ('cu-unplaced.PDF', 'cninfo:分行业', 'cninfo:其他', null, 'revenue', 'annual', 2023, 5e4, 'cninfo', 0, 5e4),
    ('cu-nested.PDF', 'cninfo:分行业', 'cninfo:煤炭', 'cninfo:能源', 'revenue', 'annual', 2022, 5e4, 'cninfo', 1, 5e4),
    ('cu-cost.PDF', 'cninfo:分行业', 'cninfo:钢铁', null, 'cost_of_revenue', 'annual', 2021, 5e4, 'cninfo', 1, 5e4),
    ('cu-quarter.PDF', 'cninfo:分行业', 'cninfo:医药', null, 'revenue', 'quarter', 2020, 5e4, 'cninfo', 1, 5e4),
    ('sec-tiny', 'x:Segments', 'x:Tiny', null, 'revenue', 'annual', 2019, 5e4, 'sec-segments', 1, 5e4),
    ('cu-queued.PDF', 'cninfo:分行业', 'cninfo:纺织', null, 'revenue', 'annual', 2018, 5e4, 'cninfo', 1, 5e4)
  ) v(acc, axis, member, parent, metric, pt, y, val, src, part, target);

delete from market.one_shot where key = 'cninfo-units-and-future-year-2026-11-23';

\i stack/supabase/migrations/20261125120000_china_s_misstated_units_and_a_future_year_are_read_again.sql

do $$
declare
  got text;
  want text := concat_ws(' | ', 'cu-cost.PDF v20', 'cu-future.PDF v0', 'cu-nested.PDF v20',
    'cu-quarter.PDF v20', 'cu-queued.PDF v0', 'cu-right.PDF v20', 'cu-tiny.PDF v0',
    'cu-unplaced.PDF v20', 'sec-tiny v20');
begin
  select string_agg(format('%s v%s', accession_number, segments_parser_version), ' | '
                    order by accession_number)
    into got
    from market.security_filing
   where security_id = '00000000-0000-0000-0000-0000000c0f01';
  if got is distinct from want then
    raise exception E'the re-queue moved the wrong reports:\n got  %\n want %', got, want;
  end if;
  if not exists (select 1 from market.one_shot
                  where key = 'cninfo-units-and-future-year-2026-11-23'
                    and reason = 're-queued 1 CNINFO reports with a revenue split under 10 m yuan '
                                 'and 1 dated after their own publication') then
    raise exception 'the repair did not record 1 + 1 reports re-queued';
  end if;
end $$;

\echo ok china-s-misstated-units-and-a-future-year-are-read-again
rollback;
