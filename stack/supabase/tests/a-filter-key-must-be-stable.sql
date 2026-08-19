-- A FILTER KEYS ON A CODE WE OWN, NEVER ON A PROVIDER'S DISPLAY STRING.
--
-- WHY THIS IS A TEST. `security_current` derived the sector as `tn.code` and the industry as
-- `n.name` — an asymmetry that was harmless while industry was only ever displayed, and became a
-- defect the moment it became filterable. "Specialty Chemicals" is a yfinance display string:
-- a provider rename makes every saved filter and every shared URL match NOTHING, silently, and
-- the user sees an empty list rather than an error.
--
-- The taxonomy carries 151 level-2 nodes with stable codes of the form `<sector>--<industry>`.
-- Those are ours and do not move.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;

-- LEVEL-2 NODES ARE LEARNED BY THE INGEST AT RUNTIME, not seeded by any migration — production has
-- 151 and a fresh database has 0. A test that needs one must create it, exactly as the
-- `data_source` / `asset_category` cases already do.
insert into market.taxonomy_node (taxonomy_id, code, name, level, sort_order, parent_id)
select 'muffin', 'information-technology--semiconductors', 'Semiconductors', 2, 1, node_id
  from market.taxonomy_node
 where taxonomy_id = 'muffin' and level = 1 and code = 'information-technology'
on conflict do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000008301', 'T83 Chipmaker', 'equity')
on conflict (security_id) do nothing;

-- Classify it at level 1 AND level 2.
insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
select '00000000-0000-0000-0000-000000008301', node_id, 'yfinance', now()
  from market.taxonomy_node
 where taxonomy_id = 'muffin' and level = 1 and code = 'information-technology'
on conflict do nothing;
insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
select '00000000-0000-0000-0000-000000008301', node_id, 'yfinance', now()
  from market.taxonomy_node
 where taxonomy_id = 'muffin' and level = 2 and code = 'information-technology--semiconductors'
on conflict do nothing;

refresh materialized view market.security_facets;

-- 1. BOTH SPELLINGS ARE SERVED. The name is what a person reads; the code is what a filter stores.
do $$
declare nm text; cd text;
begin
  select industry, industry_code into nm, cd
    from market.security_facets where security_id = '00000000-0000-0000-0000-000000008301';
  if cd is distinct from 'information-technology--semiconductors' then
    raise exception
      'industry_code is % — a filter has nothing stable to key on, so it must key on the provider display name and break silently when that is renamed', coalesce(cd,'<null>');
  end if;
  if nm is null then
    raise exception 'the display name must still be served — the code is not what a person reads';
  end if;
  if nm = cd then
    raise exception 'the name and the code are the same value (%); one of them is not what it claims to be', nm;
  end if;
end $$;

-- 2. THE CODE CARRIES ITS SECTOR, so an industry filter cannot silently span two sectors. Two
--    providers both use "Semiconductors"-style names; the code is namespaced and cannot collide.
do $$
declare cd text; sec text;
begin
  select industry_code, sector_id into cd, sec
    from market.security_facets where security_id = '00000000-0000-0000-0000-000000008301';
  if position(sec || '--' in cd) <> 1 then
    raise exception 'industry_code % is not namespaced by its sector (%) — a bare industry name can collide across sectors', cd, sec;
  end if;
end $$;

-- 3. THE AGGREGATE ACCEPTS THE CODE, both as a group_by and as a filter. A stable key the RPC
--    cannot take is a key the app cannot actually use.
do $$
declare n integer;
begin
  select count(*) into n from market.aggregate_performance(
    p_period => '1y', p_group_by => 'industry_code',
    p_industry => array['information-technology--semiconductors']);
  -- No performance rows in this fixture, so the assertion is that it RESOLVES rather than that it
  -- returns a number: an unknown group_by returns no rows, and an unknown filter matches nothing.
  if n <> 1 then
    raise exception 'grouping by industry_code and filtering by the code yielded % buckets (expected 1)', n;
  end if;
end $$;

-- 4. THE DISPLAY NAME STILL WORKS AS A FILTER. Changing the key must not strand a caller that
--    holds the old spelling — it should narrow, not return nothing.
do $$
declare n integer;
begin
  select count(*) into n from market.aggregate_performance(
    p_period => '1y', p_group_by => 'industry_code',
    p_industry => array['Semiconductors']);
  if n <> 1 then
    raise exception 'the display name stopped matching (% buckets) — switching to a code must not strand callers holding the name', n;
  end if;
end $$;

rollback;
