-- A PARSER RULE THAT STOPS EMITTING A FACT CAN NEVER RETRACT IT.
--
-- `security_segment` is written by upsert, so the parser can only ever ADD or OVERWRITE. That
-- splits the previous migration's two rules into opposite fates, which is invisible until measured:
--
--   residual demoted to partition 0 -> SELF-HEALS. The member is still emitted, at partition 0, and
--                                      overwrites its own row on the next read of that filing.
--   subtotal DROPPED                -> NEVER RETRACTS. It is discarded before it becomes a fact, so
--                                      the parser never touches that row again and the last value
--                                      written survives for ever, looking freshly written.
--
-- Measured on production the moment 176 shipped — subtotals sitting in SERVED partitions, which is
-- exactly the double count the rule was written to prevent:
--
--   us-gaap:ReportableSegmentAggregationBeforeOtherOperatingSegmentMember   partition 1   33 rows
--   us-gaap:OperatingSegmentsMember                                         partition 1    8 rows
--   us-gaap:OperatingSegmentsMember                                         partition 4    3 rows
--   ifrs-full:ReportableSegmentsMember                                      partition 1    4 rows
--   ifrs-full:ReportableSegmentsMember                                      partition 2   50 rows
--
-- The general fix is in the resource, which now retracts a filing's rows per ACCESSION before
-- rewriting them, so any future rule that stops emitting a fact removes what it used to say. This
-- migration is the ONE-SHOT that does not wait for it: a version bump re-queues every filing, and
-- the drain is days, during which a subtotal is served beside its own children.
--
-- WHY THE TWO HALVES DIFFER. A subtotal is DELETED, because the parser would never write that row
-- in any partition — leaving it at 0 would keep a row no re-read can produce. A residual-only split
-- is DEMOTED, because the parser does still emit those members at partition 0; deleting them would
-- discard a fact the filing genuinely states. Each half mirrors what a re-read now produces, which
-- is the only way the repair and the drain cannot disagree.
--
-- READ FROM THE CONTROL TABLE, never a second copy of the list — `segment_member_class` is the one
-- place a member's role is stated, and a repair that hardcoded it would drift from the parser the
-- first time a row was added.

\set ON_ERROR_STOP on

do $$
declare
  deleted bigint;
  demoted bigint;
begin
  if exists (select 1 from market.one_shot where key = 'retract-subtotals-and-residual-only-splits') then
    return;
  end if;

  -- ── subtotals: never a segment row, in any partition ──────────────────────────────────────────
  with gone as (
    delete from market.security_segment s
    using market.segment_member_class c
    where c.member_code = s.member_code and c.class = 'subtotal'
    returning 1
  )
  select count(*) into deleted from gone;

  -- ── residual-only served splits: demoted, exactly as a re-read would ──────────────────────────
  with grp as (
    select s.security_id, s.axis, s.metric_code, s.period_type, s.period_start, s.period_ending,
           s.partition_id,
           count(*) as n,
           count(*) filter (
             where exists (select 1 from market.segment_member_class c
                           where c.member_code = s.member_code and c.class = 'residual')
           ) as residual_n
    from market.security_segment s
    where s.partition_id > 0 and s.parent_member is null
    group by 1,2,3,4,5,6,7
  ),
  moved as (
    update market.security_segment s
       set partition_id = 0, reconciled_to = null
      from grp g
     where g.residual_n = g.n
       and s.security_id = g.security_id and s.axis = g.axis
       and s.metric_code = g.metric_code and s.period_type = g.period_type
       and s.period_start is not distinct from g.period_start
       and s.period_ending = g.period_ending
       and s.partition_id = g.partition_id
       and s.parent_member is null
    returning 1
  )
  select count(*) into demoted from moved;

  raise notice 'retracted % subtotal row(s), demoted % residual-only row(s)', deleted, demoted;
  insert into market.one_shot (key) values ('retract-subtotals-and-residual-only-splits');
end $$;

notify pgrst, 'reload schema';
