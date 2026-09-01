-- A MEMBER'S KIND IS NOT ITS AXIS'S KIND, and the published members need no curation — IDEMPOTENT.
--
-- `security_segment_current.kind` was read straight off `segment_axis`. That is right for the axis
-- and wrong for the member, because A COMPANY'S REPORTABLE SEGMENTS ARE OFTEN GEOGRAPHIC: they are
-- filed on `us-gaap:StatementBusinessSegmentsAxis` because that is what the company reports, and
-- the members are countries. Measured in production 2026-08-29, on the business axis:
--
--     country:TW  299.4bn   srt:NorthAmericaMember  178.2bn   srt:AsiaPacificMember  53.8bn
--     srt:SouthAmericaMember  11.6bn   us-gaap:EuropeMember  0.8bn   ifrs-full:AllOtherSegmentsMember
--
-- Two consequences, one live and one latent. The live one is that the curation queue overstated
-- itself: 113 members read as "needs a product or business concept" when 41 of them are geography
-- and never will. The latent one is worse — `derive_segment_classification` picks the axis with the
-- most MAPPED members and restricts to `kind in ('product','business')`. Nothing is wrong today
-- because no geographic member has an alias; the moment somebody reasonably maps
-- `srt:NorthAmericaMember`, TSMC's geography axis becomes eligible and WHERE the revenue is earned
-- would be written as WHAT the company does. A wrong answer that type-checks, which is the shape
-- this schema keeps meeting.
--
-- AND THE PUBLISHED MEMBERS ARE DERIVABLE, NOT AUTHORABLE. `country:US` is ISO 3166-1 alpha-2 and
-- `market.countries` has held the mapping since the reference model landed — so the geography half
-- of the queue is a join, not a curation task, the same way migration 151 fetched SEC's 444 SIC
-- codes rather than typing them. Authoring reference data from memory is what once silently
-- dropped Taiwan.
--
-- `market.segment_member` is a CONTROL TABLE, so a region member this seed has not met is a row in
-- Studio rather than a migration — and until someone adds it, it inherits the axis's kind and
-- SHOWS UP IN `pending_segment_alias`. Fail-visible, not fail-silent.

-- ── The published member vocabulary ───────────────────────────────────────────────────────────
create table if not exists market.segment_member (
  member_code  text primary key,
  kind         text not null check (kind in ('product', 'business', 'geography')),
  -- Null where the member names a REGION or a relative area rather than one country:
  -- `us-gaap:NonUsMember` is "everywhere except the US", and `ifrs-full:CountryOfDomicileMember`
  -- resolves per filer (Novo Nordisk's domicile is DK, Nokia's FI) — which is a fact about the
  -- security, not about the member, so it is not pinned here.
  country_iso2 text references market.countries (iso2),
  label        text not null,
  as_of        timestamptz not null default now()
);

comment on table market.segment_member is
  'Members whose meaning is PUBLISHED rather than filer-specific — ISO country members and the standard region members. A control table: a member met for the first time is a row here, and until it is one it inherits its axis''s kind and appears in pending_segment_alias.';

-- Derived from the country table, never typed out. `do update` because the label follows the
-- country''s own name; if a country is renamed the member follows it.
insert into market.segment_member (member_code, kind, country_iso2, label)
select 'country:' || c.iso2, 'geography', c.iso2, c.name
from market.countries c
on conflict (member_code) do update
  set kind = excluded.kind, country_iso2 = excluded.country_iso2, label = excluded.label;

-- The standard REGION members, which name an area rather than a country. Every one below was
-- measured in a real filing this pipeline has parsed, except where noted as a sibling of one that
-- was — the taxonomy publishes them as a set, and meeting the first of a set is good evidence the
-- rest will arrive. `do update` for the same reason as above.
insert into market.segment_member (member_code, kind, country_iso2, label) values
  ('srt:NorthAmericaMember',            'geography', null, 'North America'),
  ('srt:SouthAmericaMember',            'geography', null, 'South America'),
  ('srt:LatinAmericaMember',            'geography', null, 'Latin America'),
  ('srt:AmericasMember',                'geography', null, 'Americas'),
  ('srt:EuropeMember',                  'geography', null, 'Europe'),
  ('srt:EuropeanUnionMember',           'geography', null, 'European Union'),
  ('srt:AsiaMember',                    'geography', null, 'Asia'),
  ('srt:AsiaPacificMember',             'geography', null, 'Asia Pacific'),
  ('srt:AfricaMember',                  'geography', null, 'Africa'),
  ('srt:MiddleEastMember',              'geography', null, 'Middle East'),
  ('us-gaap:AsiaMember',                'geography', null, 'Asia'),
  ('us-gaap:EuropeMember',              'geography', null, 'Europe'),
  ('us-gaap:EMEAMember',                'geography', null, 'Europe, Middle East and Africa'),
  ('us-gaap:AmericasMember',            'geography', null, 'Americas'),
  ('us-gaap:NonUsMember',               'geography', null, 'Outside the United States'),
  ('ifrs-full:CountryOfDomicileMember',      'geography', null, 'Country of domicile'),
  ('ifrs-full:ForeignCountriesMember',       'geography', null, 'Foreign countries'),
  -- NOT EVERY PUBLISHED MEMBER IS A GEOGRAPHY, and seeding only the geographic ones would make the
  -- `kind = 'geography'` filter in `security_segment_geography` untestable — every labelled member
  -- would be geography and the filter could be deleted without any fixture noticing. These three
  -- were measured in production on the product axis (`us-gaap:AutomobilesMember` 44.1bn on Tesla,
  -- `us-gaap:ProductMember` 6.4bn, `us-gaap:ServiceOtherMember` 2.6bn). A label is not a concept:
  -- they still need a `segment_alias` row before two companies can be compared on them, and
  -- "Product" probably never earns one.
  ('us-gaap:AutomobilesMember',   'product',  null, 'Automobiles'),
  ('us-gaap:ProductMember',       'product',  null, 'Product'),
  ('us-gaap:ServiceOtherMember',  'product',  null, 'Service, other')
on conflict (member_code) do update
  set kind = excluded.kind, country_iso2 = excluded.country_iso2, label = excluded.label;

-- ── The serving view, with the EFFECTIVE kind ─────────────────────────────────────────────────
-- Copied from migration 150 — the CURRENT definition, not the one that introduced it. Migration
-- 106 rebuilt a table from migration 050's version and silently deleted eight later rows.
--
-- THIS FILE DROPS ITS OWN DEPENDENTS FIRST, so that re-applying it ALONE works. Without these two
-- lines the chain still passes four times — but only because migration 141 happens to run earlier
-- and clear them, which is accidental safety of exactly the kind that stops being true when files
-- are reordered. It was caught by a mutation harness that could not apply a single mutation:
-- every one reported `cannot drop view ... because other objects depend on it`, so four "guarded"
-- verdicts would have been four no-ops. A named list is right here, unlike in 141, because these
-- are this file's OWN views rather than whatever some later migration may build.
-- REPLACE FIRST, DROP ONLY IF THE SHAPE MOVED — migration 35's pattern, for its reason.
--
-- This file is now the SOLE definer of `security_segment_current`. 141, 148, 149 and 150 used to
-- define it as well, each with a different column list, so the earliest could never impose the
-- latest one's shape and had to DROP — opening a window on every deploy, roughly sixteen files
-- wide, in which the view and the segment spine did not exist. Consolidating narrowed that to one
-- file. This removes it: in steady state `create or replace` succeeds, nothing is dropped, and
-- there is no window at all. The cascade below runs only when the column list genuinely changes.
--
-- ONE DEFINITION, used by both paths. Writing the DDL twice is the same-fact-in-two-places this
-- schema has already been bitten by.
do $$
declare
  v record;
  ddl constant text := $ddl$with latest as (
  select distinct on (g.security_id, g.axis, g.member_code, g.metric_code)
    g.security_id, g.axis, g.member_code, g.metric_code,
    g.value, g.currency_code, g.period_ending, g.accession_number
  from market.security_segment_latest g
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
  p.security_id, p.axis,
  -- THE MEMBER WINS. A country filed on the business-segments axis is still a country.
  coalesce(sm.kind, a.kind) as kind,
  p.member_code,
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
  p.currency_code, p.period_ending, p.accession_number,
  -- Appended: what the member is called and where it is, when that is knowable without curation.
  sm.country_iso2,
  sm.label as member_label
from pivoted p
-- A SCALAR SUBQUERY, NOT A JOIN. `segment_axis` is keyed (taxonomy, axis) and the `srt:` axes are
-- shared between us-gaap and ifrs-full filers, so a plain join returns every row twice.
cross join lateral (
  select ax.kind from market.segment_axis ax where ax.axis = p.axis
  order by ax.priority desc, ax.taxonomy limit 1
) a
left join market.segment_member sm on sm.member_code = p.member_code
left join lateral (
  select g.value from market.security_segment_latest g
  where g.security_id = p.security_id and g.axis = p.axis and g.member_code = p.member_code
    and g.metric_code = 'total_assets' and g.period_type = 'instant' and g.partition_id = 1
    and g.parent_member is null and g.period_ending <= p.period_ending
  order by g.period_ending desc limit 1
) ast on true
-- SAME REASON, AND THE SPECIFIC ALIAS MUST WIN. A member can carry both a company-scoped mapping
-- and a generic one; `security_id is not null` sorts first so the scoped alias is chosen.
left join lateral (
  select al.concept_code from market.segment_alias al
  where al.member_code = p.member_code
    and (al.security_id = p.security_id or al.security_id is null)
  order by (al.security_id is not null) desc limit 1
) al on true
left join market.segment_concept c on c.code = al.concept_code
$ddl$;
begin
  begin
    execute 'create or replace view market.security_segment_current as ' || ddl;
    return;                     -- unchanged: nothing dropped, no window
  exception when others then
    null;                       -- the column list moved; the cascade below is now required
  end;

  raise notice '  --  157: security_segment_current shape changed, rebuilding dependents';

  -- RELKIND-AWARE and DISCOVERED, never a named list. This file used to name
  -- `security_segment_geography` and `pending_segment_alias`; migration 158 later built
  -- `security_segment_spine` — a MATERIALIZED view — on the same source, and the list could not
  -- see it. `drop view if exists` raises `is not a view` for a matview and `IF EXISTS` does not
  -- help, so the kind has to be branched on.
  for v in
    select distinct dv.relname as name, dv.relkind as kind
    from pg_depend d
    join pg_rewrite r   on r.oid = d.objid
    join pg_class dv    on dv.oid = r.ev_class
    join pg_class src   on src.oid = d.refobjid
    join pg_namespace n on n.oid = src.relnamespace
    where n.nspname = 'market'
      and src.relname = 'security_segment_current'
      and dv.relname <> 'security_segment_current'
      and dv.relkind in ('v', 'm')
  loop
    if v.kind = 'm' then
      execute format('drop materialized view if exists market.%I cascade', v.name);
    else
      execute format('drop view if exists market.%I cascade', v.name);
    end if;
  end loop;

  execute 'drop view if exists market.security_segment_current cascade';
  execute 'create view market.security_segment_current as ' || ddl;
end $$;

comment on view market.security_segment_current is
  'Latest annual revenue and operating income per disclosed business line, with each line''s share of its own split. Restricted to partition 1 — the finest split that reconciles to the filing — so the rows on one (security, axis) can safely be summed. `kind` is the MEMBER''s kind where that is published (a country filed on the business axis is geography), falling back to the axis''s. operating_margin_pct is a SEGMENT margin: it excludes unallocated corporate cost by design and does not roll up to the company''s operating margin.';

-- ── Where a company earns, with no curation at all ────────────────────────────────────────────
-- `security_segment_geography` is defined once, in migration 158 — see the note there. Defining a view
-- in several migrations forces the earliest to DROP (a `create or replace` cannot reorder or
-- rename columns), and that drop cascades to its dependents on every single deploy.

-- ── The curation queue ────────────────────────────────────────────────────────────────────────
-- What a human still has to decide, ranked by LEVERAGE rather than by size.
--
-- IT IS NOT ORDERED BY REVENUE, AND THAT IS THE POINT. Revenue is denominated in the filer's own
-- currency, so TSMC's 3,272,600,000,000 TWD outranks every US line by three orders of magnitude
-- while being about the same size company — the same trap `security_peers` met when ranking on
-- `market_cap` instead of `security_market_cap_usd`. `revenue_share_pct` is a percentage and is
-- therefore free of currency, and it answers the question that matters: how much of this company
-- is the line nobody has mapped. Companies-sharing-the-member comes first, because a concept is
-- only worth anything once TWO companies sit on it.
-- `pending_segment_alias` is defined once, in migration 162 — see the note there. Defining a view
-- in several migrations forces the earliest to DROP (a `create or replace` cannot reorder or
-- rename columns), and that drop cascades to its dependents on every single deploy.

-- ── Grants ────────────────────────────────────────────────────────────────────────────────────
-- `drop view` DISCARDS THE ACL, so every re-grant below is load-bearing rather than tidy.
-- `security_segment_geography` is granted in 158 and `pending_segment_alias` in 162, where each is
-- now defined. A grant naming a relation this file no longer creates would abort the whole
-- migration — and because these apply `--single-transaction`, that leaves the view above uncreated
-- and every later file failing on it.
grant select on market.segment_member, market.security_segment_current
  to anon, authenticated, service_role;
grant insert, update, delete on market.segment_member to service_role;

alter table market.segment_member enable row level security;
drop policy if exists segment_member_read on market.segment_member;
create policy segment_member_read on market.segment_member for select using (true);

notify pgrst, 'reload schema';
