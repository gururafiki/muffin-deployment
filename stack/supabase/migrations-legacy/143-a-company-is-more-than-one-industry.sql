-- A COMPANY IS MORE THAN ONE INDUSTRY, AND THE SEGMENTS SAY BY HOW MUCH.
--
-- THE COMPLAINT THIS ANSWERS. Amazon is classified consumer-discretionary, which is true and
-- useless: AWS is ~19% of its revenue and roughly 60% of its operating income, and that is what
-- moves the valuation. A single sector label cannot express it, and no provider sells the answer —
-- but the filings state it, and migration 141 now stores it.
--
-- MEASURED FIRST, 2026-08-28. `security_taxonomy` is modelled many-to-many over `source_code`
-- precisely so several opinions can coexist, and at level 2 that capacity was **entirely unused**:
-- 7,754 industry rows over 7,754 securities, a distribution of exactly `{1: 7754}`, every one from
-- yfinance. The multiplicity was designed and never populated. This migration populates it.
--
-- NOTHING EXISTING CHANGES, AND THAT IS DELIBERATE. Every new source is seeded at a priority BELOW
-- yfinance (100), so `security_current.sector_id`, the `security_facets` spine, the sector pages
-- and every donut resolve exactly as they do today. The new rows are additive and are read through
-- `security_industries`, which is a new view. A weighted classification is a better answer to a
-- different question — it is not a replacement for the label a page puts in its header.

-- ── A classification can now carry a WEIGHT ───────────────────────────────────────────────────
--
-- Nullable, and null for every existing row. "Amazon is 19% information-technology" and "yfinance
-- says Amazon is consumer-discretionary" are different kinds of statement, and only the first has
-- a number. A `default 1` would have been worse than null: it would assert that every provider
-- opinion is a 100% weighting, which is exactly the single-label claim this migration exists to
-- stop making.
alter table market.security_taxonomy add column if not exists weight numeric;

comment on column market.security_taxonomy.weight is
  'How much of the company this classification accounts for, 0..1 — revenue share for `segment-revenue`, operating-income share for `segment-profit`. NULL for a provider opinion, which asserts a category without quantifying it.';

insert into market.data_source (code, name, priority) values
  -- BELOW yfinance (100) ON PURPOSE. These must never win `security_current.sector_id`, or every
  -- sector page, the facets matview and the Markets donut would silently re-bucket the ~3,500
  -- securities that have segments while the other ~8,800 kept their provider label — one universe
  -- classified two ways, which is worse than either.
  ('segment-revenue', 'Derived from disclosed segment revenue',          45),
  ('segment-profit',  'Derived from disclosed segment operating income', 40),
  ('wikidata',        'Wikidata (crowd-sourced, multi-valued)',          30)
on conflict (code) do update set name = excluded.name, priority = excluded.priority;

-- ── The derivation ────────────────────────────────────────────────────────────────────────────
--
-- PURE SQL, NO PROVIDER, so it inherits none of the machinery the fetching resources need: no
-- 90-second worker limit, no rate limit, no batching, no negative cache. The same argument that
-- made `derive_security_metrics` a function rather than an edge resource.
create or replace function market.derive_segment_classification()
returns integer
language plpgsql
security definer
set search_path = market, pg_catalog, pg_temp
as $$
declare written integer := 0;
begin
  -- ONE AXIS PER (SECURITY, METRIC), AND THE DENOMINATOR IS THE WHOLE SPLIT.
  --
  -- Both halves of that sentence are corrections, and the first version got both wrong in ways
  -- that produced confident, plausible, wrong numbers — measured on Amazon's real FY2025 figures.
  --
  -- 1. UNIONING THE AXES IS THE DOUBLE COUNT THIS SCHEMA IS BUILT TO PREVENT. AWS is disclosed
  --    twice — `amzn:AmazonWebServicesMember` on the product axis and
  --    `amzn:AmazonWebServicesSegmentMember` on the business axis, same 128,725,000,000 — so
  --    taking both put 257,450,000,000 of cloud into a denominator that also counted it twice, and
  --    reported information technology at **0.3066** where the truth is 0.1796. The shares still
  --    summed to 1.0, which is exactly why it survived a first reading.
  --
  -- 2. A DENOMINATOR OF ONLY THE MAPPED MEMBERS INVENTS CERTAINTY. Amazon's profit is disclosed by
  --    business segment, and two of those three segments are GEOGRAPHIC (North America,
  --    International) and deliberately have no concept — so dividing by the mapped total alone
  --    reported information technology at **1.0000**: "Amazon is 100% a technology company by
  --    profit". Dividing by the whole split gives 47/79 = **0.5949**, which is both the honest
  --    number and the well-known one. What is unmapped is simply not attributed, and the weights
  --    correctly no longer sum to 1.
  --
  -- The axis is chosen per METRIC because a filer may disclose revenue on one and profit on
  -- another — Amazon gives seven product lines of revenue and three business segments of operating
  -- income. Most mapped members wins, then the axis's declared priority, then the name so the
  -- choice is deterministic.
  with candidate as (
    select
      c.security_id, c.axis, g.metric_code,
      count(*) filter (where sc.node_id is not null) as mapped_members,
      max(a.priority) as axis_priority
    from market.security_segment g
    join market.security_segment_current c
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
    where g.partition_id = 1 and g.period_type = 'annual'
      and g.period_ending = (
        select max(g2.period_ending) from market.security_segment g2
         where g2.security_id = g.security_id and g2.axis = g.axis
           and g2.metric_code = g.metric_code and g2.partition_id = 1
           and g2.period_type = 'annual')
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
    join market.security_segment_current c
      on c.security_id = g.security_id and c.axis = g.axis and c.member_code = g.member_code
    join market.segment_concept sc on sc.code = c.concept_code
    where g.partition_id = 1 and g.period_type = 'annual' and sc.node_id is not null
      and g.period_ending = (
        select max(g2.period_ending) from market.security_segment g2
         where g2.security_id = g.security_id and g2.axis = g.axis
           and g2.metric_code = g.metric_code and g2.partition_id = 1
           and g2.period_type = 'annual')
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
  delete from market.security_taxonomy st
   where st.source_code in ('segment-revenue', 'segment-profit')
     and not exists (
       select 1 from market.security_segment_current c
       join market.segment_concept sc on sc.code = c.concept_code
       where c.security_id = st.security_id and sc.node_id = st.node_id
         and c.kind in ('product', 'business')
     );

  return written;
end $$;

comment on function market.derive_segment_classification() is
  'Turns disclosed segment revenue and operating income into weighted rows in security_taxonomy. Pure SQL — no provider, no rate limit, no backlog. Deletes weights whose segments no longer map, because an upsert cannot retract.';

-- ── Serving every classification, not just the winner ─────────────────────────────────────────
--
-- `security_current` answers "what is this company's sector" with ONE row, chosen by source
-- priority, and every existing page depends on that. This view answers the different question the
-- data can now support: what is this company classified as, by whom, and how much of it.
drop view if exists market.security_industries;
create view market.security_industries as
select
  st.security_id,
  tn.node_id,
  tn.code,
  tn.name,
  tn.level,
  parent.code as parent_code,
  parent.name as parent_name,
  st.source_code,
  ds.priority   as source_priority,
  st.weight,
  st.as_of
from market.security_taxonomy st
join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin'
left join market.taxonomy_node parent on parent.node_id = tn.parent_id
join market.data_source ds on ds.code = st.source_code;

comment on view market.security_industries is
  'EVERY classification a security carries, with its source, the source''s priority and — where the classification is derived from disclosed segments — its weight. `security_current` serves the single winning sector for a page header; this serves the whole picture, which is what makes "Amazon is 19% cloud by revenue and 60% by operating income" expressible.';

grant select on market.security_industries to anon, authenticated, service_role;
revoke all on function market.derive_segment_classification() from public;
grant execute on function market.derive_segment_classification() to service_role;

notify pgrst, 'reload schema';
