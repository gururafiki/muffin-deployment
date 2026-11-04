-- `sector_constituents` MUST RESOLVE INDUSTRIES ONCE, NOT ONCE PER CONSTITUENT.
--
-- WHY. The industry was a `LEFT JOIN LATERAL ( ... limit 1)` per constituent. On 2026-11-04 that ran
-- 13,058 times for one read of the whole view, and `data_defect`, which reads it whole, timed out
-- as anon in market-verify. The same per-row shape cost the weights 14 s in September (#391).
--
-- A TIMING CANNOT FAIL ON A FIXTURE, so this counts the work: in the plan of a whole-view read, no
-- scan of `taxonomy_node` that carries the parent condition may run more than once. The lateral
-- form runs it once per constituent (42 here); the hash-joined form scans the industries once and
-- applies the parent in the join.
--
-- And the rule itself, with fixtures that make the candidate rules disagree:
--   * an industry under ANOTHER sector is not served (dropping the parent from the join serves it);
--   * two industries under the served sector give the first by name (a reversed order gives the
--     other; the lateral's unordered `limit 1` gave whichever the plan reached).

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZS','Sectoria','ZS',false)
  on conflict (iso2) do nothing;
insert into market.data_source (code, name, priority) values ('tsc-src','TSC source', 100)
  on conflict (code) do nothing;
insert into market.taxonomy (taxonomy_id, name) values ('muffin','Muffin') on conflict do nothing;
insert into market.taxonomy_node (node_id, taxonomy_id, code, name, level, parent_id) values
  ('00000000-0000-0000-0000-000001104001','muffin','tsc-sector','TSC Sector',   1, null),
  ('00000000-0000-0000-0000-000001104002','muffin','tsc-other', 'TSC Other',    1, null),
  ('00000000-0000-0000-0000-000001104011','muffin','tsc-alpha', 'TSC Alpha',    2, '00000000-0000-0000-0000-000001104001'),
  ('00000000-0000-0000-0000-000001104012','muffin','tsc-beta',  'TSC Beta',     2, '00000000-0000-0000-0000-000001104001'),
  ('00000000-0000-0000-0000-000001104013','muffin','tsc-else',  'TSC Elsewhere',2, '00000000-0000-0000-0000-000001104002')
on conflict (node_id) do nothing;

-- Forty ordinary constituents, each in the sector with one industry under it.
insert into market.security (security_id, name, security_type_code, country_iso2)
select format('00000000-0000-0000-0001-%s', lpad(i::text, 12, '0'))::uuid, 'TSC Co ' || i, 'equity', 'ZS'
  from generate_series(1, 40) i;
insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
select format('00000000-0000-0000-0001-%s', lpad(i::text, 12, '0'))::uuid, n.node_id, 'tsc-src', now()
  from generate_series(1, 40) i
  cross join (values ('00000000-0000-0000-0000-000001104001'::uuid),
                     ('00000000-0000-0000-0000-000001104012'::uuid)) n(node_id);

-- TWO industries under the served sector: the first by name, Alpha, is served.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0002-000000000001', 'TSC Two Industries', 'equity', 'ZS'),
  -- An industry only under ANOTHER sector: none is served under this one.
  ('00000000-0000-0000-0002-000000000002', 'TSC Misfiled', 'equity', 'ZS');
insert into market.security_taxonomy (security_id, node_id, source_code, as_of) values
  ('00000000-0000-0000-0002-000000000001','00000000-0000-0000-0000-000001104001','tsc-src', now()),
  ('00000000-0000-0000-0002-000000000001','00000000-0000-0000-0000-000001104012','tsc-src', now()),
  ('00000000-0000-0000-0002-000000000001','00000000-0000-0000-0000-000001104011','tsc-src', now()),
  ('00000000-0000-0000-0002-000000000002','00000000-0000-0000-0000-000001104001','tsc-src', now()),
  ('00000000-0000-0000-0002-000000000002','00000000-0000-0000-0000-000001104013','tsc-src', now());

do $$
declare
  plan jsonb;
  scans int;
  per_row int;
  n int;
  ind text;
begin
  execute 'explain (analyze, format json) select * from market.sector_constituents' into plan;

  select count(*),
         count(*) filter (where (node->>'Actual Loops')::int > 1
                            and concat_ws(' ', node->>'Filter', node->>'Index Cond', node->>'Recheck Cond')
                                like '%parent_id%')
    into scans, per_row
    from jsonb_path_query(plan, 'strict $.**') node
   where jsonb_typeof(node) = 'object' and node->>'Relation Name' = 'taxonomy_node';

  -- The floor: a plan with no taxonomy_node scan at all would pass the rule below vacuously.
  if scans = 0 then
    raise exception 'the plan scans taxonomy_node nowhere — the check below would pass on nothing';
  end if;
  if per_row > 0 then
    raise exception 'sector_constituents resolves the industry once per constituent (% taxonomy_node scan(s) with the parent condition ran more than once) — the per-row lateral that timed data_defect out on 2026-11-04', per_row;
  end if;

  select count(*) into n from market.sector_constituents where sector_id = 'tsc-sector';
  if n <> 42 then
    raise exception 'expected the 42 fixture constituents in tsc-sector, got %', n;
  end if;

  select industry into ind from market.sector_constituents
   where sector_id = 'tsc-sector' and security_id = '00000000-0000-0000-0002-000000000002';
  if ind is not null then
    raise exception 'served industry % under tsc-sector for a security whose only industry belongs to ANOTHER sector', ind;
  end if;

  select industry into ind from market.sector_constituents
   where sector_id = 'tsc-sector' and security_id = '00000000-0000-0000-0002-000000000001';
  if ind is distinct from 'TSC Alpha' then
    raise exception 'two industries under the served sector must give the first by name (TSC Alpha), got %', coalesce(ind, 'null');
  end if;

  select count(*) into n from market.sector_constituents
   where sector_id = 'tsc-sector' and industry = 'TSC Beta';
  if n <> 40 then
    raise exception 'expected the 40 ordinary constituents served TSC Beta, got %', n;
  end if;
end $$;

rollback;

\echo 'ok: sector_constituents resolves industries once, inside the served sector'
