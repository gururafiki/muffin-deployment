-- AN INDUSTRY MUST BELONG TO THE SECTOR IT IS SERVED UNDER.
--
-- WHY. `security_current` picked the industry with `n.level = 2` and no constraint on whose child
-- the node is, while `sector_constituents` required `n.parent_id = tn.node_id`. The stock page and
-- the sector page therefore disagreed about the same company. Measured in production: Uber, Paychex
-- and ADP are classified `industrials` and served a `Software - Application` industry, as are LDOS,
-- FIS, BALL, AMCR and EXO.AS.
--
-- It is not cosmetic. `security_facets.industry_code` is built from this view, so those pairs
-- surface on the coverage dashboard as industry buckets that do not exist —
-- `industrials--software-application` (3 securities), `financials--software-infrastructure` (2),
-- `materials--packaging-containers` (4). Nine securities filed under three industries no taxonomy
-- contains, on a panel whose whole job is to say where coverage is thin.
--
-- THE FIXTURE MAKES THE RULES DISAGREE. The security carries TWO level-2 nodes: one under a sector
-- it is NOT classified in, from a HIGHER-priority source, and one under the sector it is. Ordering
-- by source priority alone picks the wrong one — which is exactly what shipped. A fixture with a
-- single industry passes under either rule and proves nothing.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZI','Industria','ZI',false)
  on conflict (iso2) do nothing;
-- A HIGHER priority than the source of the correct industry, so the unconstrained rule prefers it.
insert into market.data_source (code, name, priority) values
  ('t165-high','T165 high priority', 900),
  ('t165-low', 'T165 low priority',  100)
on conflict (code) do nothing;

insert into market.taxonomy (taxonomy_id, name) values ('muffin','Muffin') on conflict do nothing;
insert into market.taxonomy_node (node_id, taxonomy_id, code, name, level, parent_id) values
  ('00000000-0000-0000-0000-000000016501','muffin','t165-industrials','T165 Industrials',1,null),
  ('00000000-0000-0000-0000-000000016502','muffin','t165-tech',       'T165 Technology', 1,null),
  ('00000000-0000-0000-0000-000000016511','muffin','t165-machinery',  'T165 Machinery',  2,'00000000-0000-0000-0000-000000016501'),
  ('00000000-0000-0000-0000-000000016512','muffin','t165-software',   'T165 Software',   2,'00000000-0000-0000-0000-000000016502')
on conflict (node_id) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000016591', 'T165 Ride Hailing', 'equity', 'ZI')
on conflict (security_id) do nothing;

insert into market.security_taxonomy (security_id, node_id, source_code, as_of) values
  -- The SECTOR: industrials, from the low-priority source.
  ('00000000-0000-0000-0000-000000016591','00000000-0000-0000-0000-000000016501','t165-low', now()),
  -- The industry under THAT sector — correct, but low priority.
  ('00000000-0000-0000-0000-000000016591','00000000-0000-0000-0000-000000016511','t165-low', now()),
  -- An industry under a DIFFERENT sector, from the high-priority source. The unconstrained rule
  -- takes this one, which is the shipped bug.
  ('00000000-0000-0000-0000-000000016591','00000000-0000-0000-0000-000000016512','t165-high', now())
on conflict do nothing;

do $$
declare sec text; ind text; ind_code text;
begin
  select sector_id, industry, industry_code into sec, ind, ind_code
  from market.security_current
   where security_id = '00000000-0000-0000-0000-000000016591';

  if sec <> 't165-industrials' then
    raise exception 'the fixture is not exercising the rule: sector is % rather than t165-industrials', sec;
  end if;

  if ind_code = 't165-software' then
    raise exception 'security_current serves industry % under sector % — the industry is a child of a DIFFERENT sector, which is how `industrials--software-application` became a bucket on the coverage dashboard', ind_code, sec;
  end if;
  if ind_code is distinct from 't165-machinery' then
    raise exception 'expected the industry under the served sector (t165-machinery), got % — constraining the parent must not stop a CORRECT industry being served', coalesce(ind_code,'null');
  end if;
  if ind is distinct from 'T165 Machinery' then
    raise exception 'industry NAME is % but industry_code is % — the two subqueries must agree, or the page shows one and filters by the other', coalesce(ind,'null'), ind_code;
  end if;
end $$;

rollback;

\echo 'ok: an industry is served only under the sector it is a child of'
