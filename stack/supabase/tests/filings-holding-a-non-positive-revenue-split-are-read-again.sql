-- The re-queue of 2026-11-21 (migration 20261121120000) puts behind the parser every read filing
-- holding a revenue split that totals, or is reconciled to, zero or less, and touches nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database re-queues nothing, so applying the
-- migration set proves nothing about it. The fixture holds one filing of each kind the rule must
-- tell apart, and makes each grouping column load-bearing: a coarser group would hide the
-- non-positive half behind a positive one beside it.
--   re-queued:
--     acc-target     a split of 337 reconciled to -9 (Univest's shape)
--     acc-sum        an inherited split (no target) summing to -5
--     acc-zero       a split summing to exactly 0 against a positive target
--     acc-partition  partition 1 sums to 10, partition 2 to -3, on one axis and period
--     acc-axis       axis A sums to 10, axis B to -3, in one period
--     acc-period     2024 sums to 5, 2025 to -2, on one axis
--     acc-nested     flat members sum to 10, a cross-tab parent's cells to -2
--     acc-shared     for the security whose split it is, and only that one
--   untouched:
--     acc-good       a split with an elimination line, summing to its positive target
--     acc-loss       segment operating income reconciled to a loss (profit may be negative)
--     acc-unplaced   a negative revenue member at partition 0 (not a split)
--     acc-queued     already behind the parser (and not counted)
--     acc-unread     never read (it is due already)
--     acc-shared     for the sibling security under the same accession, with no split of its own

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('t-seg','Test segments',100)
  on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order) values
  ('revenue', 'Revenue', 'income', 'currency', true, false, 1),
  ('operating_income', 'Operating income', 'income', 'currency', true, false, 2)
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-00000000d0a1', 'D0A1 Filer', 'equity'),
  ('00000000-0000-0000-0000-00000000d0a2', 'D0A2 Sibling', 'equity')
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, source_code, segments_parsed_at, segments_parser_version)
select '00000000-0000-0000-0000-00000000d0a1'::uuid, acc, 't-seg', timestamptz '2026-11-20', 20
  from unnest(array['acc-target','acc-sum','acc-zero','acc-partition','acc-axis','acc-period',
                    'acc-nested','acc-shared','acc-good','acc-loss','acc-unplaced']) acc
union all select '00000000-0000-0000-0000-00000000d0a1', 'acc-queued', 't-seg',
                 timestamptz '2026-11-20', 0
union all select '00000000-0000-0000-0000-00000000d0a1', 'acc-unread', 't-seg', null, null
union all select '00000000-0000-0000-0000-00000000d0a2', 'acc-shared', 't-seg',
                 timestamptz '2026-11-20', 20;

insert into market.security_segment
  (security_id, accession_number, axis, member_code, parent_axis, parent_member, metric_code,
   period_type, period_start, period_ending, value, source_code, partition_id, reconciled_to)
select s.security_id::uuid, s.acc, s.axis, s.member, s.p_axis, s.p_member, s.metric, 'annual',
       (s.ending - interval '1 year' + interval '1 day')::date, s.ending, s.value, 't-seg',
       s.part, s.target
  from (values
    -- security, accession, axis, member, parent axis, parent member, metric, period end, value,
    -- partition, reconciled_to
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-target', 'ax:target', 'm:a', null, null,
     'revenue', date '2025-12-31', 200, 1, -9),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-target', 'ax:target', 'm:b', null, null,
     'revenue', date '2025-12-31', 137, 1, -9),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-sum', 'ax:sum', 'm:a', null, null,
     'revenue', date '2025-12-31', 3, 1, null),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-sum', 'ax:sum', 'm:b', null, null,
     'revenue', date '2025-12-31', -8, 1, null),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-zero', 'ax:zero', 'm:a', null, null,
     'revenue', date '2025-12-31', 0, 1, 100),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-zero', 'ax:zero', 'm:b', null, null,
     'revenue', date '2025-12-31', 0, 1, 100),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-partition', 'ax:partition', 'm:a', null, null,
     'revenue', date '2025-12-31', 10, 1, 10),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-partition', 'ax:partition', 'm:b', null, null,
     'revenue', date '2025-12-31', -3, 2, null),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-axis', 'ax:axis-a', 'm:a', null, null,
     'revenue', date '2025-12-31', 10, 1, 10),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-axis', 'ax:axis-b', 'm:a', null, null,
     'revenue', date '2025-12-31', -3, 1, null),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-period', 'ax:period', 'm:a', null, null,
     'revenue', date '2024-12-31', 5, 1, 5),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-period', 'ax:period', 'm:a', null, null,
     'revenue', date '2025-12-31', -2, 1, null),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-nested', 'ax:nested', 'm:flat', null, null,
     'revenue', date '2025-12-31', 10, 1, 10),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-nested', 'ax:nested', 'm:cell-a', 'ax:parent',
     'm:parent', 'revenue', date '2025-12-31', -1, 1, null),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-nested', 'ax:nested', 'm:cell-b', 'ax:parent',
     'm:parent', 'revenue', date '2025-12-31', -1, 1, null),
    ('00000000-0000-0000-0000-00000000d0a2', 'acc-shared', 'ax:shared', 'm:a', null, null,
     'revenue', date '2025-12-31', -4, 1, -4),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-good', 'ax:good', 'm:a', null, null,
     'revenue', date '2025-12-31', 60, 1, 100),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-good', 'ax:good', 'm:b', null, null,
     'revenue', date '2025-12-31', 50, 1, 100),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-good', 'ax:good', 'm:elim', null, null,
     'revenue', date '2025-12-31', -10, 1, 100),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-loss', 'ax:loss', 'm:a', null, null,
     'operating_income', date '2025-12-31', -10, 1, -30),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-loss', 'ax:loss', 'm:b', null, null,
     'operating_income', date '2025-12-31', -20, 1, -30),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-unplaced', 'ax:unplaced', 'm:a', null, null,
     'revenue', date '2025-12-31', -5, 0, null),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-queued', 'ax:queued', 'm:a', null, null,
     'revenue', date '2025-12-31', 5, 1, -1),
    ('00000000-0000-0000-0000-00000000d0a1', 'acc-unread', 'ax:unread', 'm:a', null, null,
     'revenue', date '2025-12-31', 5, 1, -1)
  ) s(security_id, acc, axis, member, p_axis, p_member, metric, ending, value, part, target);

delete from market.one_shot where key = 'segments-requeue-non-positive-2026-11-21';

\i stack/supabase/migrations/20261121120000_filings_holding_a_non_positive_revenue_split_are_read_again.sql

do $$
declare
  got text;
  want text := concat_ws(' | ',
    'd0a1 acc-axis v0', 'd0a1 acc-good v20', 'd0a1 acc-loss v20', 'd0a1 acc-nested v0',
    'd0a1 acc-partition v0', 'd0a1 acc-period v0', 'd0a1 acc-queued v0', 'd0a1 acc-shared v20',
    'd0a1 acc-sum v0', 'd0a1 acc-target v0', 'd0a1 acc-unplaced v20', 'd0a1 acc-unread v-',
    'd0a1 acc-zero v0', 'd0a2 acc-shared v0');
begin
  select string_agg(
           concat_ws(' ', right(security_id::text, 4), accession_number,
                     'v' || coalesce(segments_parser_version::text, '-')),
           ' | ' order by security_id, accession_number)
    into got
    from market.security_filing
   where security_id::text like '00000000-0000-0000-0000-00000000d0a_';

  if got is distinct from want then
    raise exception E'the non-positive re-queue touched the wrong filings\n got: %\nwant: %',
      got, want;
  end if;
  if exists (select 1 from market.security_filing
              where security_id::text like '00000000-0000-0000-0000-00000000d0a_'
                and segments_parser_version = 0 and segments_parsed_at is null) then
    raise exception 'a re-queued filing must keep its read time, so the lane reports a re-read';
  end if;
  if not exists (select 1 from market.one_shot
                  where key = 'segments-requeue-non-positive-2026-11-21'
                    and reason like 're-queued 8 %') then
    raise exception 'the re-queue must record how many it re-queued, the already-queued excluded';
  end if;
  raise notice 'ok  only filings holding a non-positive revenue split are behind the parser';
end $$;

-- ONE-SHOT: once the lane has read a filing again, it is not re-queued.
update market.security_filing set segments_parser_version = 21
 where accession_number = 'acc-target';

\i stack/supabase/migrations/20261121120000_filings_holding_a_non_positive_revenue_split_are_read_again.sql

do $$
begin
  if (select segments_parser_version from market.security_filing
       where accession_number = 'acc-target') is distinct from 21 then
    raise exception 'the re-queue ran twice; its key in market.one_shot is what stops that';
  end if;
  raise notice 'ok  the re-queue is one-shot';
end $$;

rollback;
