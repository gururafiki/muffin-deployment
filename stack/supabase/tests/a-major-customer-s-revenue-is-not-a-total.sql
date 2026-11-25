-- `ifrs-full:MajorCustomersAxis` is no qualifier, and the one-shot of migration 20261126090000
-- re-queues every DART report holding a revenue row, and nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database matches nothing. Each fixture row is
-- kept out by exactly one clause:
--   re-queued:
--     d-rev       a DART report with a revenue row
--   untouched:
--     d-cost      a DART report whose only row is a cost (the rule reads revenue)
--     d-none      a DART report with no row at all
--     sec-ifrs    an SEC report with an IFRS revenue row (another source: measured unchanged)
--     d-queued    a DART report with a revenue row, already behind the parser (not counted)

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('dart', 'DART', 100), ('sec-segments', 'SEC segments', 100)
on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order) values
  ('revenue', 'Revenue', 'income', 'currency', true, false, 1),
  ('cost_of_revenue', 'Cost of revenue', 'income', 'currency', true, false, 2)
on conflict (code) do nothing;
insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-0000000d0c01', 'MC01', 'equity')
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, source_code, segments_parsed_at, segments_parser_version,
   report_type, report_date)
select '00000000-0000-0000-0000-0000000d0c01', acc, src, '2026-11-20', v, rt, '2026-03-18'::date
  from (values
    ('d-rev', 'dart', 20, '사업보고서'),
    ('d-cost', 'dart', 20, '사업보고서'),
    ('d-none', 'dart', 20, '사업보고서'),
    ('sec-ifrs', 'sec-submissions', 20, '20-F'),
    ('d-queued', 'dart', 0, '사업보고서')
  ) v(acc, src, v, rt);

insert into market.security_segment
  (security_id, accession_number, axis, member_code, parent_member, metric_code, period_type,
   period_start, period_ending, value, source_code, partition_id, reconciled_to)
select '00000000-0000-0000-0000-0000000d0c01', acc, axis, member, null, metric, 'annual',
       '2025-01-01', '2025-12-31', val, src, 1, 9.45e12
  from (values
    ('d-rev', 'ifrs-full:GeographicalAreasAxis', 'ifrs-full:CountryOfDomicileMember', 'revenue', 3.16e12, 'dart'),
    ('d-cost', 'ifrs-full:GeographicalAreasAxis', 'dart:CNMember', 'cost_of_revenue', 2.0e12, 'dart'),
    ('sec-ifrs', 'ifrs-full:SegmentsAxis', 'x:Spirits', 'revenue', 1.0e10, 'sec-segments'),
    ('d-queued', 'ifrs-full:SegmentsAxis', 'dart:Payments', 'revenue', 9.7e10, 'dart')
  ) v(acc, axis, member, metric, val, src);

-- The state before the migration: the row it deletes is back, as migration 155 left it, or a
-- migration that deletes nothing would pass against a database where the real one already ran.
insert into market.segment_axis (taxonomy, axis, kind, priority, required_member)
values ('ifrs-full', 'ifrs-full:MajorCustomersAxis', 'qualifier', 0, null)
on conflict (taxonomy, axis) do nothing;
delete from market.one_shot where key = 'dart-major-customers-2026-11-26';

\i stack/supabase/migrations/20261126090000_a_major_customer_s_revenue_is_not_a_total.sql

do $$
declare
  got text;
  want text := concat_ws(' | ', 'd-cost v20', 'd-none v20', 'd-queued v0', 'd-rev v0', 'sec-ifrs v20');
begin
  if exists (select 1 from market.segment_axis where axis = 'ifrs-full:MajorCustomersAxis') then
    raise exception 'MajorCustomersAxis is still in the vocabulary: a customer group''s revenue reads as a company total';
  end if;
  if (select count(*) from market.segment_axis
       where axis in ('ifrs-full:TimingOfTransferOfGoodsOrServicesAxis',
                      'ifrs-full:ConsolidatedAndSeparateFinancialStatementsAxis')
         and kind = 'qualifier') <> 2 then
    raise exception 'the delete took another qualifier with it';
  end if;
  select string_agg(format('%s v%s', accession_number, segments_parser_version), ' | '
                    order by accession_number)
    into got
    from market.security_filing
   where security_id = '00000000-0000-0000-0000-0000000d0c01';
  if got is distinct from want then
    raise exception E'the re-queue moved the wrong reports:\n got  %\n want %', got, want;
  end if;
  if not exists (select 1 from market.one_shot
                  where key = 'dart-major-customers-2026-11-26'
                    and reason = 're-queued 1 DART reports holding a revenue row') then
    raise exception 'the repair did not record 1 report re-queued';
  end if;
end $$;

\echo ok a-major-customer-s-revenue-is-not-a-total
rollback;
