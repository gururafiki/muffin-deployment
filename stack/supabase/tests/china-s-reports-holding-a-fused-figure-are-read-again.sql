-- The re-queue of 2026-11-22 (migration 20261122140000) puts behind the parser every read CNINFO
-- report holding a member name with a money figure fused into it, and touches nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database matches nothing. Each fixture row is
-- kept out by exactly one clause:
--   re-queued:
--     cn-fused      a CNINFO report whose member carries `16,327,089.58` in its name
--     cn-negative   a revenue split placed with no target (China Eastern FY2020's shape)
--   untouched:
--     cn-clean      a CNINFO report with ordinary names
--     cn-share      a CNINFO name carrying a share and no money figure (`钒钛铁精矿（61%）`)
--     cn-unplaced   revenue rows with no target at partition 0 (unplaced, as #195 leaves them)
--     cn-cell       a cross-tab cell placed with no target of its own (its parent's is elsewhere)
--     cn-cost       a cost row placed with no target
--     cn-queued     a fused report already behind the parser
--     sec-fused     the same name on an SEC filing (another source)

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
  ('00000000-0000-0000-0000-00000000cf01', 'CF01 Filer', 'equity')
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, source_code, segments_parsed_at, segments_parser_version)
values
  ('00000000-0000-0000-0000-00000000cf01', 'cn-fused.PDF', 'cninfo', '2026-11-20', 20),
  ('00000000-0000-0000-0000-00000000cf01', 'cn-clean.PDF', 'cninfo', '2026-11-20', 20),
  ('00000000-0000-0000-0000-00000000cf01', 'cn-share.PDF', 'cninfo', '2026-11-20', 20),
  ('00000000-0000-0000-0000-00000000cf01', 'cn-queued.PDF', 'cninfo', '2026-11-20', 0),
  ('00000000-0000-0000-0000-00000000cf01', 'cn-negative.PDF', 'cninfo', '2026-11-20', 20),
  ('00000000-0000-0000-0000-00000000cf01', 'cn-unplaced.PDF', 'cninfo', '2026-11-20', 20),
  ('00000000-0000-0000-0000-00000000cf01', 'cn-cell.PDF', 'cninfo', '2026-11-20', 20),
  ('00000000-0000-0000-0000-00000000cf01', 'cn-cost.PDF', 'cninfo', '2026-11-20', 20),
  ('00000000-0000-0000-0000-00000000cf01', 'sec-fused', 'sec-submissions', '2026-11-20', 20);

insert into market.security_segment
  (security_id, accession_number, axis, member_code, metric_code, period_type, period_start,
   period_ending, value, source_code, partition_id, reconciled_to)
select '00000000-0000-0000-0000-00000000cf01'::uuid, acc, axis, member, metric, 'annual',
       date '2019-01-01', date '2019-12-31', 1, src, part, target
  from (values
    ('cn-fused.PDF',  'cninfo:分行业', 'cninfo:其他业务16,327,089.580.36%', 'cninfo', 'revenue', 1, 1),
    ('cn-fused.PDF',  'cninfo:分行业', 'cninfo:医药制造业4,502,304,602.8399.64%', 'cninfo', 'revenue', 1, 1),
    ('cn-clean.PDF',  'cninfo:分行业', 'cninfo:医药制造业', 'cninfo', 'revenue', 1, 1),
    ('cn-share.PDF',  'cninfo:分产品', 'cninfo:钒钛铁精矿（61%）', 'cninfo', 'revenue', 1, 1),
    ('cn-queued.PDF', 'cninfo:分地区', 'cninfo:华东1,590,906,920.5035.20%', 'cninfo', 'revenue', 1, 1),
    ('sec-fused',     'x:Axis', 'x:其他业务16,327,089.580.36%', 'sec-segments', 'revenue', 1, 1),
    -- The segment key leaves out the accession, so each of these needs a member of its own.
    ('cn-negative.PDF', 'cninfo:分行业', 'cninfo:航空运输业务', 'cninfo', 'revenue', 1, null),
    ('cn-unplaced.PDF', 'cninfo:分行业', 'cninfo:旅游业务', 'cninfo', 'revenue', 0, null),
    ('cn-cost.PDF',   'cninfo:分行业', 'cninfo:货运业务', 'cninfo', 'cost_of_revenue', 1, null)
  ) v(acc, axis, member, src, metric, part, target);

-- A cell under a parent, placed with no target of its own: not the shape #195 refuses.
insert into market.security_segment
  (security_id, accession_number, axis, member_code, parent_axis, parent_member, metric_code,
   period_type, period_start, period_ending, value, source_code, partition_id, reconciled_to)
values ('00000000-0000-0000-0000-00000000cf01', 'cn-cell.PDF', 'cninfo:分行业', 'cninfo:其中一项',
        'cninfo:分行业', 'cninfo:航空运输业务', 'revenue', 'annual', '2019-01-01', '2019-12-31', 1,
        'cninfo', 1, null);

delete from market.one_shot where key = 'cninfo-requeue-fused-figure-2026-11-22';

\i stack/supabase/migrations/20261122140000_china_s_reports_holding_a_fused_figure_are_read_again.sql

do $$
declare
  got text;
  want text := concat_ws(' | ', 'cn-cell.PDF v20', 'cn-clean.PDF v20', 'cn-cost.PDF v20',
    'cn-fused.PDF v0', 'cn-negative.PDF v0', 'cn-queued.PDF v0', 'cn-share.PDF v20',
    'cn-unplaced.PDF v20', 'sec-fused v20');
begin
  select string_agg(format('%s v%s', accession_number, segments_parser_version), ' | '
                    order by accession_number)
    into got
    from market.security_filing
   where security_id = '00000000-0000-0000-0000-00000000cf01';
  if got is distinct from want then
    raise exception E'the fused-figure re-queue moved the wrong reports:\n got  %\n want %', got, want;
  end if;
  if not exists (select 1 from market.one_shot
                  where key = 'cninfo-requeue-fused-figure-2026-11-22'
                    and reason like 're-queued 2 %') then
    raise exception 'the re-queue did not record itself as having re-queued 2 reports';
  end if;
end $$;

\echo ok china-s-reports-holding-a-fused-figure-are-read-again
rollback;
