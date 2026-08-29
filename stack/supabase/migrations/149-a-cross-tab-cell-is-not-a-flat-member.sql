-- A CROSS-TAB CELL IS NOT A FLAT MEMBER, AND UNTIL NOW IT WAS THROWN AWAY.
--
-- Alphabet tags Search, YouTube, Network and Subscriptions with `ProductOrServiceAxis` **and**
-- `StatementBusinessSegmentsAxis = GoogleServices` at the same time — product lines listed WITHIN
-- a reportable segment. The parser required exactly one segment axis and rejected all of them,
-- which was the right call while there was nowhere to put them (mislabelling a cell as a flat
-- member is the double count this whole schema exists to prevent) and is why **YouTube's revenue
-- was not in the database**.
--
-- Measured on the FY2025 10-K:
--     Search        224,532,000,000  \
--     Subscriptions  48,030,000,000   |  sum = 342,721,000,000
--     YouTube        40,367,000,000   |       = Google Services exactly
--     Network        29,792,000,000  /
--     Advertising   294,691,000,000  = Search + YouTube + Network — a SUBTOTAL
--
-- So the nested level has exactly the shape of the top one: a set that reconciles, and subtotals
-- beside it. The only thing that changes is WHAT IT RECONCILES TO — the parent member's own value
-- (342,721,000,000), not the company's consolidated revenue (402,836,000,000). Reconciling a
-- nested set against the company places none of it.
--
-- THE READER'S RULE IS UNCHANGED AND NOW HAS A SECOND CLAUSE: aggregate within one partition, and
-- within ONE LEVEL. Summing Google Services beside its own four product lines counts the segment
-- twice, exactly as summing two axes does.

alter table market.security_segment add column if not exists parent_axis   text;
alter table market.security_segment add column if not exists parent_member text;

comment on column market.security_segment.parent_member is
  'For a fact tagged with TWO segment axes, the coarser member it sits inside — Alphabet''s Search is a product line WITHIN Google Services. NULL for an ordinary flat member. A nested row''s siblings sum to the PARENT''s value, not to the company''s consolidated figure, so nested and flat rows must never be summed together.';

-- THE PRIMARY KEY MUST CARRY THE PARENT, or a nested cell and a flat member of the same axis
-- collide and one silently replaces the other on upsert — the same failure `period_type` was added
-- to the key to prevent, one level down. `coalesce` because a primary key admits no NULLs and the
-- flat case must keep working.
alter table market.security_segment drop constraint if exists security_segment_pkey;
alter table market.security_segment add column if not exists parent_key text
  generated always as (coalesce(parent_member, '')) stored;
alter table market.security_segment add constraint security_segment_pkey
  primary key (security_id, axis, member_code, parent_key, metric_code, period_type, period_ending);

-- ── Serving: the two levels are DELIBERATELY two views ────────────────────────────────────────
--
-- `security_segment_current` keeps its exact contract — top-level members only — so nothing that
-- reads it can start double counting because a filer began disclosing a nested breakdown. The
-- nested lines get their own view, and a caller has to ask for them.
drop view if exists market.security_segment_current;
create view market.security_segment_current as
with latest as (
  select distinct on (g.security_id, g.axis, g.member_code, g.metric_code)
    g.security_id, g.axis, g.member_code, g.metric_code,
    g.value, g.currency_code, g.period_ending, g.accession_number
  from market.security_segment g
  where g.partition_id = 1 and g.period_type = 'annual' and g.parent_member is null
  order by g.security_id, g.axis, g.member_code, g.metric_code, g.period_ending desc
),
pivoted as (
  select
    l.security_id, l.axis, l.member_code,
    max(l.currency_code)                                             as currency_code,
    max(l.period_ending)                                             as period_ending,
    max(l.accession_number)                                          as accession_number,
    max(l.value) filter (where l.metric_code = 'revenue')             as revenue,
    max(l.value) filter (where l.metric_code = 'operating_income')    as operating_income,
    max(l.value) filter (where l.metric_code = 'capital_expenditure') as capital_expenditure,
    max(l.value) filter (where l.metric_code = 'depreciation')        as depreciation,
    max(l.value) filter (where l.metric_code = 'cost_of_revenue')     as cost_of_revenue
  from latest l
  group by l.security_id, l.axis, l.member_code
)
select
  p.security_id, p.axis, a.kind, p.member_code,
  c.code as concept_code, c.name as concept_name,
  p.revenue, p.operating_income, p.capital_expenditure, p.depreciation, p.cost_of_revenue,
  ast.value as total_assets,
  case when p.revenue is not null and p.revenue <> 0
       then round(100 * p.operating_income / p.revenue, 2) end as operating_margin_pct,
  case when p.revenue is not null and p.revenue <> 0 and p.cost_of_revenue is not null
       then round(100 * (p.revenue - p.cost_of_revenue) / p.revenue, 2) end as gross_margin_pct,
  case when p.depreciation is not null and p.depreciation <> 0
       then round(p.capital_expenditure / p.depreciation, 2) end as capex_to_depreciation,
  case when ast.value is not null and ast.value <> 0
       then round(100 * p.operating_income / ast.value, 2) end as return_on_segment_assets_pct,
  round(100 * p.revenue / nullif(sum(p.revenue) over (partition by p.security_id, p.axis), 0), 2)
    as revenue_share_pct,
  p.currency_code, p.period_ending, p.accession_number
from pivoted p
cross join lateral (
  select ax.kind from market.segment_axis ax where ax.axis = p.axis
  order by ax.priority desc, ax.taxonomy limit 1
) a
left join lateral (
  select g.value from market.security_segment g
  where g.security_id = p.security_id and g.axis = p.axis and g.member_code = p.member_code
    and g.metric_code = 'total_assets' and g.period_type = 'instant' and g.partition_id = 1
    and g.parent_member is null and g.period_ending <= p.period_ending
  order by g.period_ending desc limit 1
) ast on true
left join lateral (
  select al.concept_code from market.segment_alias al
  where al.member_code = p.member_code
    and (al.security_id = p.security_id or al.security_id is null)
  order by (al.security_id is not null) desc limit 1
) al on true
left join market.segment_concept c on c.code = al.concept_code;

comment on view market.security_segment_current is
  'Latest annual revenue, operating income, capex, depreciation and cost of revenue per TOP-LEVEL business line, with segment assets and the ratios that follow. Restricted to partition 1 and to flat members, so the rows on one (security, axis) can safely be summed. Nested product lines live in `security_segment_detail` — summing the two together counts a segment twice.';

-- ── The nested level ──────────────────────────────────────────────────────────────────────────
drop view if exists market.security_segment_detail;
create view market.security_segment_detail as
with latest as (
  select distinct on (g.security_id, g.parent_member, g.axis, g.member_code, g.metric_code)
    g.security_id, g.parent_axis, g.parent_member, g.axis, g.member_code, g.metric_code,
    g.value, g.currency_code, g.period_ending
  from market.security_segment g
  where g.partition_id = 1 and g.period_type = 'annual' and g.parent_member is not null
  order by g.security_id, g.parent_member, g.axis, g.member_code, g.metric_code,
           g.period_ending desc
),
pivoted as (
  select
    l.security_id, l.parent_axis, l.parent_member, l.axis, l.member_code,
    max(l.currency_code) as currency_code,
    max(l.period_ending) as period_ending,
    max(l.value) filter (where l.metric_code = 'revenue')          as revenue,
    max(l.value) filter (where l.metric_code = 'operating_income') as operating_income
  from latest l
  group by l.security_id, l.parent_axis, l.parent_member, l.axis, l.member_code
)
select
  p.security_id, p.parent_axis, p.parent_member, p.axis, p.member_code,
  c.code as concept_code, c.name as concept_name,
  p.revenue, p.operating_income,
  -- Share OF THE PARENT, which is the only denominator that means anything at this level.
  round(100 * p.revenue
        / nullif(sum(p.revenue) over (partition by p.security_id, p.parent_member, p.axis), 0), 2)
    as share_of_parent_pct,
  p.currency_code, p.period_ending
from pivoted p
left join lateral (
  select al.concept_code from market.segment_alias al
  where al.member_code = p.member_code
    and (al.security_id = p.security_id or al.security_id is null)
  order by (al.security_id is not null) desc limit 1
) al on true
left join market.segment_concept c on c.code = al.concept_code;

comment on view market.security_segment_detail is
  'Product lines disclosed WITHIN a reportable segment — Alphabet''s Search, YouTube, Network and Subscriptions inside Google Services. Their share is OF THE PARENT, not of the company. Never sum these beside `security_segment_current`: the parent is already there and would be counted twice.';

grant select on market.security_segment_current, market.security_segment_detail
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
