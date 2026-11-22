-- The one-shot of 2026-11-22 (migration 20261122130000) unplaces UBS's edge rows on its two 20-Fs
-- over the 32 MB gate, and touches nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database matches nothing, so applying the
-- migration set proves nothing about it. Each filter in its WHERE clause has a fixture row that only
-- that filter keeps out:
--   unplaced:
--     the two named accessions, every metric and period, at partition 1
--   untouched:
--     a UBS row at partition 1 on another accession              (the accession list)
--     a row at partition 1 on a named accession, another CIK     (the CIK)
--     a row at partition 1 on a named accession, another source  (the source)
--     a UBS row already at partition 0, keeping its target        (partition_id > 0)

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('sec-segments', 'SEC segments', 100), ('t-other', 'Another source', 50)
on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order) values
  ('revenue', 'Revenue', 'income', 'currency', true, false, 1),
  ('total_assets', 'Total assets', 'balance', 'currency', false, false, 2)
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, cik) values
  ('00000000-0000-0000-0000-00000000ab01', 'UBS Group', 'equity', 1610520),
  ('00000000-0000-0000-0000-00000000ab02', 'Another filer', 'equity', 1999999)
on conflict (security_id) do nothing;

insert into market.security_segment
  (security_id, accession_number, axis, member_code, metric_code, period_type, period_start,
   period_ending, value, source_code, partition_id, reconciled_to)
values
  -- the eight rows the edge wrote (2026-08-30), as production holds them
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-20-000041', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentCCMember', 'revenue', 'annual', '2017-01-01', '2017-12-31', -68000000,
   'sec-segments', 1, 29754000000),
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-20-000041', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentCCMember', 'total_assets', 'instant', '2017-12-31', '2017-12-31', 115064000000,
   'sec-segments', 1, 29754000000),
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-20-000041', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentCCMember', 'revenue', 'annual', '2018-01-01', '2018-12-31', -617000000,
   'sec-segments', 1, 30330000000),
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-20-000041', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentCCMember', 'total_assets', 'instant', '2018-12-31', '2018-12-31', 113656000000,
   'sec-segments', 1, 30330000000),
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-20-000041', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentCCMember', 'revenue', 'annual', '2019-01-01', '2019-12-31', -378000000,
   'sec-segments', 1, 28967000000),
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-20-000041', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentCCMember', 'total_assets', 'instant', '2019-12-31', '2019-12-31', 102592000000,
   'sec-segments', 1, 28967000000),
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-21-000035', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentGFMember', 'revenue', 'annual', '2018-01-01', '2018-12-31', -617000000,
   'sec-segments', 1, 30330000000),
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-21-000035', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentGFMember', 'total_assets', 'instant', '2018-12-31', '2018-12-31', 113667000000,
   'sec-segments', 1, 30330000000),
  -- untouched
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-22-000010', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentGWMMember', 'revenue', 'annual', '2021-01-01', '2021-12-31', 19000000000,
   'sec-segments', 1, 35000000000),
  ('00000000-0000-0000-0000-00000000ab02', '0001610520-20-000041', 'ifrs-full:SegmentsAxis',
   'x:OtherMember', 'revenue', 'annual', '2019-01-01', '2019-12-31', 5,
   'sec-segments', 1, 5),
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-21-000035', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentGFMember', 'revenue', 'annual', '2020-01-01', '2020-12-31', 7,
   't-other', 1, 7),
  ('00000000-0000-0000-0000-00000000ab01', '0001610520-21-000035', 'ifrs-full:SegmentsAxis',
   'ubs:SegmentIBMember', 'revenue', 'annual', '2020-01-01', '2020-12-31', 9,
   'sec-segments', 0, 9);

delete from market.one_shot where key = 'ubs-too-large-rows-unplaced-2026-11-22';

\i stack/supabase/migrations/20261122130000_ubs_rows_on_filings_too_large_to_read_are_unplaced.sql

do $$
declare
  got text;
  want text := concat_ws(' | ',
    '0ab01 0001610520-20-000041 revenue 2017-12-31 sec-segments p0 t=',
    '0ab01 0001610520-20-000041 revenue 2018-12-31 sec-segments p0 t=',
    '0ab01 0001610520-20-000041 revenue 2019-12-31 sec-segments p0 t=',
    '0ab01 0001610520-20-000041 total_assets 2017-12-31 sec-segments p0 t=',
    '0ab01 0001610520-20-000041 total_assets 2018-12-31 sec-segments p0 t=',
    '0ab01 0001610520-20-000041 total_assets 2019-12-31 sec-segments p0 t=',
    '0ab01 0001610520-21-000035 revenue 2018-12-31 sec-segments p0 t=',
    '0ab01 0001610520-21-000035 revenue 2020-12-31 sec-segments p0 t=9',
    '0ab01 0001610520-21-000035 revenue 2020-12-31 t-other p1 t=7',
    '0ab01 0001610520-21-000035 total_assets 2018-12-31 sec-segments p0 t=',
    '0ab01 0001610520-22-000010 revenue 2021-12-31 sec-segments p1 t=35000000000',
    '0ab02 0001610520-20-000041 revenue 2019-12-31 sec-segments p1 t=5');
begin
  select string_agg(format('%s %s %s %s %s p%s t=%s', right(security_id::text, 5),
                           accession_number, metric_code, period_ending, source_code,
                           partition_id, reconciled_to),
                    ' | ' order by right(security_id::text, 5), accession_number, metric_code,
                                   period_ending, source_code)
    into got
    from market.security_segment
   where security_id in ('00000000-0000-0000-0000-00000000ab01',
                         '00000000-0000-0000-0000-00000000ab02');
  if got is distinct from want then
    raise exception E'the UBS one-shot changed the wrong rows:\n got  %\n want %', got, want;
  end if;
  if not exists (select 1 from market.one_shot
                  where key = 'ubs-too-large-rows-unplaced-2026-11-22'
                    and reason like 'unplaced 8 %') then
    raise exception 'the one-shot did not record itself as having unplaced 8 rows';
  end if;
end $$;

-- A second application changes nothing and records nothing new.
update market.security_segment set partition_id = 1
 where security_id = '00000000-0000-0000-0000-00000000ab01'
   and accession_number = '0001610520-20-000041' and metric_code = 'revenue'
   and period_ending = '2017-12-31';

\i stack/supabase/migrations/20261122130000_ubs_rows_on_filings_too_large_to_read_are_unplaced.sql

do $$
begin
  if (select partition_id from market.security_segment
       where security_id = '00000000-0000-0000-0000-00000000ab01'
         and accession_number = '0001610520-20-000041' and metric_code = 'revenue'
         and period_ending = '2017-12-31') <> 1 then
    raise exception 'a second application of the one-shot ran again';
  end if;
end $$;

\echo ok ubs-rows-on-filings-too-large-to-read-are-unplaced
rollback;
