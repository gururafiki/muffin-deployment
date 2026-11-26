-- The repair of 2026-11-26 (migration 20261126120000) re-queues the CNINFO reports the older-forms
-- fix can change, and nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database matches nothing. Each fixture row is
-- kept in or out by exactly one clause:
--   re-queued:
--     co-old          a full report published 2011 holding a revenue row
--     co-tiny         a 2020 report holding a placed, top-level, annual revenue split of 52,332
--     co-fused        a 2021 report holding the member `应收账款12,493.19`
--   untouched:
--     co-oldcost   a 2011 full report holding only a cost row (no revenue row: the user's call)
--     co-oldsum    a 2011 summary holding a revenue row (not a full report)
--     co-newer        a 2020 full report with a 1.2 bn split and clean names
--     co-unplaced     a 2020 tiny revenue member at partition 0
--     co-year         a 2022 member named `2010年新产品`: a year is no figure
--     sec-older       an SEC filing of 2011 with a revenue row (another source)
--     co-queued       a 2011 report already behind the parser (not counted)

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
  ('00000000-0000-0000-0000-0000000c0f02', 'CO01', 'equity')
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, source_code, segments_parsed_at, segments_parser_version,
   report_type, report_date)
select '00000000-0000-0000-0000-0000000c0f02', acc, src, '2026-11-25', v, rt, d::date
  from (values
    ('co-old.PDF', 'cninfo', 20, '年度报告', '2011-04-30'),
    ('co-tiny.PDF', 'cninfo', 20, '年度报告', '2020-04-30'),
    ('co-fused.PDF', 'cninfo', 20, '年度报告', '2021-04-30'),
    ('co-oldcost.PDF', 'cninfo', 20, '年度报告', '2011-04-29'),
    ('co-oldsum.PDF', 'cninfo', 20, '年度报告摘要', '2011-04-28'),
    ('co-newer.PDF', 'cninfo', 20, '年度报告', '2020-04-29'),
    ('co-unplaced.PDF', 'cninfo', 20, '年度报告', '2020-04-28'),
    ('co-year.PDF', 'cninfo', 20, '年度报告', '2022-04-30'),
    ('sec-older', 'sec-submissions', 20, '10-K', '2011-02-28'),
    ('co-queued.PDF', 'cninfo', 0, '年度报告', '2011-04-27')
  ) v(acc, src, v, rt, d);

insert into market.security_segment
  (security_id, accession_number, axis, member_code, parent_member, metric_code, period_type,
   period_start, period_ending, value, source_code, partition_id, reconciled_to)
select '00000000-0000-0000-0000-0000000c0f02', acc, axis, member, null, metric, 'annual',
       make_date(y, 1, 1), make_date(y, 12, 31), val, src, part, target
  from (values
    ('co-old.PDF', 'cninfo:分行业', 'cninfo:医药', 'revenue', 2010, 7.1e8, 'cninfo', 1, 7.1e8),
    ('co-tiny.PDF', 'cninfo:分行业', 'cninfo:原料药', 'revenue', 2019, 52332, 'cninfo', 1, 52332),
    ('co-fused.PDF', 'cninfo:分地区', 'cninfo:应收账款12,493.19', 'revenue', 2020, 1.2e9, 'cninfo', 1, 1.2e9),
    ('co-oldcost.PDF', 'cninfo:分行业', 'cninfo:钢铁', 'cost_of_revenue', 2009, 5e8, 'cninfo', 1, 5e8),
    ('co-oldsum.PDF', 'cninfo:分行业', 'cninfo:煤炭', 'revenue', 2008, 5e8, 'cninfo', 1, 5e8),
    ('co-newer.PDF', 'cninfo:分行业', 'cninfo:电力', 'revenue', 2018, 1.2e9, 'cninfo', 1, 1.2e9),
    ('co-unplaced.PDF', 'cninfo:分行业', 'cninfo:其他', 'revenue', 2017, 5e4, 'cninfo', 0, 5e4),
    ('co-year.PDF', 'cninfo:分产品', 'cninfo:2010年新产品', 'revenue', 2021, 1.2e9, 'cninfo', 1, 1.2e9),
    ('sec-older', 'x:Segments', 'x:Older', 'revenue', 2010, 5e8, 'sec-segments', 1, 5e8),
    ('co-queued.PDF', 'cninfo:分行业', 'cninfo:纺织', 'revenue', 2007, 5e8, 'cninfo', 1, 5e8)
  ) v(acc, axis, member, metric, y, val, src, part, target);

delete from market.one_shot where key = 'cninfo-older-tables-2026-11-26';

\i stack/supabase/migrations/20261126120000_china_s_older_tables_are_read_again.sql

do $$
declare
  got text;
  want text := concat_ws(' | ', 'co-fused.PDF v0', 'co-newer.PDF v20', 'co-old.PDF v0',
    'co-oldcost.PDF v20', 'co-oldsum.PDF v20', 'co-queued.PDF v0', 'co-tiny.PDF v0',
    'co-unplaced.PDF v20', 'co-year.PDF v20', 'sec-older v20');
begin
  select string_agg(format('%s v%s', accession_number, segments_parser_version), ' | '
                    order by accession_number)
    into got
    from market.security_filing
   where security_id = '00000000-0000-0000-0000-0000000c0f02';
  if got is distinct from want then
    raise exception E'the re-queue moved the wrong reports:\n got  %\n want %', got, want;
  end if;
  if not exists (select 1 from market.one_shot
                  where key = 'cninfo-older-tables-2026-11-26'
                    and reason = 're-queued 1 older CNINFO reports with a revenue row, 1 with a '
                                 'split under 10 m yuan and 1 with a figure in a member name') then
    raise exception 'the repair did not record 1 + 1 + 1 reports re-queued';
  end if;
end $$;

\echo ok china-s-older-tables-are-read-again
rollback;
