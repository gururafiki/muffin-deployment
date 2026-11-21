CREATE OR REPLACE FUNCTION market.derive_segment_classification()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare written integer := 0;
begin
  -- ONE AXIS PER (SECURITY, METRIC), AND THE DENOMINATOR IS THE WHOLE SPLIT.
  --
  -- 1. UNIONING THE AXES IS THE DOUBLE COUNT THIS SCHEMA IS BUILT TO PREVENT. AWS is disclosed
  --    twice — `amzn:AmazonWebServicesMember` on the product axis and
  --    `amzn:AmazonWebServicesSegmentMember` on the business axis, same 128,725,000,000 — so
  --    taking both put 257,450,000,000 of cloud into a denominator that also counted it twice, and
  --    reported information technology at 0.3066 where the truth is 0.1796. The shares still
  --    summed to 1.0, which is exactly why it survived a first reading.
  --
  -- 2. A DENOMINATOR OF ONLY THE MAPPED MEMBERS INVENTS CERTAINTY. Amazon's profit is disclosed by
  --    business segment, two of those three segments are GEOGRAPHIC and deliberately have no
  --    concept, so dividing by the mapped total alone reported information technology at 1.0000 —
  --    "Amazon is 100% a technology company by profit". Dividing by the whole split gives 47/79 =
  --    0.5949, both the honest number and the well-known one.
  --
  -- The axis is chosen per METRIC because a filer may disclose revenue on one and profit on
  -- another. Most mapped members wins, then the axis's declared priority, then the name so the
  -- choice is deterministic.
  with latest as (
    -- ONE AGGREGATE, NOT A CORRELATED SUBQUERY PER ROW. Same answer, 191,098 fewer scans.
    select security_id, axis, metric_code, max(period_ending) as pe
    from market.security_segment
    where partition_id = 1 and period_type = 'annual'
    group by 1, 2, 3
  ),
  candidate as (
    select
      c.security_id, c.axis, g.metric_code,
      count(*) filter (where sc.node_id is not null) as mapped_members,
      max(a.priority) as axis_priority
    from market.security_segment g
    -- THE SPINE, NOT THE VIEW. Whole-table access is what migration 158 materialised it for.
    join market.security_segment_spine c
      on c.security_id = g.security_id and c.axis = g.axis and c.member_code = g.member_code
    join market.segment_axis a on a.axis = g.axis
    left join market.segment_concept sc on sc.code = c.concept_code
    where g.partition_id = 1 and g.period_type = 'annual'
      and c.kind in ('product', 'business')
    group by c.security_id, c.axis, g.metric_code
  ),
  chosen as (
    select distinct on (security_id, metric_code) security_id, metric_code, axis
    from candidate
    where mapped_members > 0
    order by security_id, metric_code, mapped_members desc, axis_priority desc, axis
  ),
  -- The split's FULL total, including members nobody has mapped. This is the denominator.
  split_total as (
    select g.security_id, g.metric_code, sum(greatest(g.value, 0)) as total
    from market.security_segment g
    join chosen ch
      on ch.security_id = g.security_id and ch.metric_code = g.metric_code and ch.axis = g.axis
    join latest l
      on l.security_id = g.security_id and l.axis = g.axis and l.metric_code = g.metric_code
    where g.partition_id = 1 and g.period_type = 'annual' and g.period_ending = l.pe
    group by g.security_id, g.metric_code
  ),
  -- Several members can map to one node (a filer disclosing "AWS" and "Cloud services"
  -- separately), so collapse before dividing — and before the insert, or the statement carries the
  -- same conflict key twice and Postgres rejects the whole thing with SQLSTATE 21000.
  by_node as (
    -- CLAMPED AT THE NODE, NOT THE MEMBER. A business line that nets a loss contributes nothing,
    -- and summing only its profitable members would report a division as earning money the company
    -- did not make. The DENOMINATOR clamps per member instead, because members nobody has mapped
    -- have no node to net into — the asymmetry is deliberate and keeps every weight in [0, 1].
    select g.security_id, g.metric_code, sc.node_id, greatest(sum(g.value), 0) as value
    from market.security_segment g
    join chosen ch
      on ch.security_id = g.security_id and ch.metric_code = g.metric_code and ch.axis = g.axis
    join market.security_segment_spine c
      on c.security_id = g.security_id and c.axis = g.axis and c.member_code = g.member_code
    join market.segment_concept sc on sc.code = c.concept_code
    join latest l
      on l.security_id = g.security_id and l.axis = g.axis and l.metric_code = g.metric_code
    where g.partition_id = 1 and g.period_type = 'annual' and sc.node_id is not null
      and g.period_ending = l.pe
    group by g.security_id, g.metric_code, sc.node_id
  ),
  emitted as (
    insert into market.security_taxonomy (security_id, node_id, source_code, weight, as_of)
    select
      n.security_id, n.node_id,
      case n.metric_code when 'revenue' then 'segment-revenue' else 'segment-profit' end,
      -- CLAMPED AT ZERO IN BOTH THE NUMERATOR AND THE DENOMINATOR (`greatest` above). A segment
      -- can lose money, and a negative in the denominator makes a share EXCEED 1 — with cloud +48
      -- and retail -8 an unclamped share is 48/40 = 1.2. A negative weight would also sort a
      -- loss-making division above a profitable one under `order by weight desc`.
      round(n.value / nullif(t.total, 0), 4),
      now()
    from by_node n
    join split_total t
      on t.security_id = n.security_id and t.metric_code = n.metric_code
    where n.metric_code in ('revenue', 'operating_income')
      and t.total > 0
    -- `do update`, not `do nothing`: these rows are DERIVED, so a recomputation must replace them.
    -- The memberships that upsert `do nothing` are editorial choices a redeploy must not revert; a
    -- share of revenue is arithmetic and has no curation to protect.
    on conflict (security_id, node_id, source_code)
      do update set weight = excluded.weight, as_of = excluded.as_of
    returning 1
  )
  select count(*) into written from emitted;

  -- AN UPSERT CANNOT RETRACT. A security whose segments stopped mapping to a node keeps the weight
  -- written last time, for ever, looking freshly derived — the same defect the performance cache
  -- had, where a period the refresh stopped producing outlived the fix that stopped producing it.
  --
  -- THE SPINE HERE TOO. This `not exists` is correlated over `security_taxonomy`, so reading the
  -- view made it the third whole-table evaluation in one statement.
  delete from market.security_taxonomy st
   where st.source_code in ('segment-revenue', 'segment-profit')
     and not exists (
       select 1 from market.security_segment_spine c
       join market.segment_concept sc on sc.code = c.concept_code
       where c.security_id = st.security_id and sc.node_id = st.node_id
         and c.kind in ('product', 'business')
     );

  return written;
end $function$;
