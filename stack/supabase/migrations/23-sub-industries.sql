-- Populate taxonomy level 2 (industry), and stop the sector views seeing it — IDEMPOTENT.
--
-- `taxonomy_node.parent_id` has modelled sector -> industry group -> industry -> sub-industry since
-- the reference model landed, and only level 1 was ever filled. That is why the sector page shows
-- no sub-sector chips: the authored slugs ('software-saas') had nothing behind them and were
-- removed rather than left as decoration.
--
-- The data was already arriving and being discarded. yfinance's `equity/profile` returns
-- `industry_category` in the SAME response `security-profiles` already reads for the sector —
-- verified in production against `market.instruments`, which the older resource fills:
-- NVDA "Semiconductors", MSFT "Software - Infrastructure", BAC "Banks - Diversified".
--
-- Industries live in the `muffin` taxonomy under their sector rather than in a separate provider
-- one, so the tree is a single tree — which is what `parent_id` is for. `security_taxonomy.
-- source_code` still records that yfinance is the one saying it.

-- Fifth instance of the pattern, added up front this time rather than after a drain loop spun:
-- a security whose profile carries no industry must stop being re-asked.
alter table market.security add column if not exists industry_missing_at timestamptz;

-- ── the sector views must not pick up level 2 ────────────────────────────────
-- Both join `taxonomy_id = 'muffin'` and would otherwise match a security's SECTOR row and its
-- INDUSTRY row, reintroducing exactly the duplication that migration 18 removed.

-- DROP before CREATE, always, for a view any LATER migration also defines. `create or replace`
-- cannot rename or reorder columns, and every migration re-runs in order on every deploy — so
-- whichever file runs first keeps trying to impose its own column list on the other's. Third time
-- this has failed a deploy.
drop view if exists market.sector_constituents;
create view market.sector_constituents as
select distinct on (tn.code, s.security_id)
  tn.code        as sector_id,
  s.security_id,
  s.name,
  t.symbol,
  s.country_iso2,
  ind.name       as industry,
  h.weight,
  h.market_value,
  h.as_of
from market.security_taxonomy st
join market.taxonomy_node tn
  on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
join market.data_source ds   on ds.code = st.source_code
join market.security s       on s.security_id = st.security_id
left join lateral (
  select i.value as symbol
  from market.security_identifier i
  where i.security_id = s.security_id and i.kind_code = 'ticker'
  order by i.value
  limit 1
) t on true
-- The security's industry: a level-2 node whose parent is the sector it is being listed under, so
-- a company cannot show an industry from a different sector.
left join lateral (
  select n.name
  from market.security_taxonomy st2
  join market.taxonomy_node n
    on n.node_id = st2.node_id and n.taxonomy_id = 'muffin' and n.level = 2
   and n.parent_id = tn.node_id
  where st2.security_id = s.security_id
  limit 1
) ind on true
left join lateral (
  select h.weight, h.market_value, h.as_of
  from market.fund_holding_current h
  join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf on tf.symbol = fi.value and tf.represents_code = tn.code
  where h.security_id = s.security_id
  limit 1
) h on true
order by tn.code, s.security_id, ds.priority desc, st.as_of desc;

drop view if exists market.fund_sector_weight;
create view market.fund_sector_weight as
with classified as (
  select distinct on (st.security_id) st.security_id, tn.code
  from market.security_taxonomy st
  join market.taxonomy_node tn
    on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
  join market.data_source ds on ds.code = st.source_code
  order by st.security_id, ds.priority desc, st.as_of desc
)
select
  fi.value as fund_symbol,
  coalesce(c.code, 'unclassified') as sector_id,
  sum(h.weight) as weight,
  round(100 * sum(h.weight) / nullif(sum(sum(h.weight)) over (partition by fi.value), 0), 4) as weight_pct,
  max(h.as_of) as as_of
from market.fund_holding_current h
join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
left join classified c on c.security_id = h.security_id
where h.security_id <> h.fund_id
group by fi.value, coalesce(c.code, 'unclassified');

-- ── the backlog ──────────────────────────────────────────────────────────────
-- Securities that already have a yfinance SECTOR but no industry. They are re-fetched once; the
-- sector upsert is idempotent, so the only new cost is the industry.
create or replace view market.pending_industry as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_taxonomy sec_st on sec_st.security_id = s.security_id
join market.taxonomy_node sec_n
  on sec_n.node_id = sec_st.node_id and sec_n.taxonomy_id = 'muffin' and sec_n.level = 1
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join market.security_taxonomy ind_st on ind_st.security_id = s.security_id
left join market.taxonomy_node ind_n
  on ind_n.node_id = ind_st.node_id and ind_n.taxonomy_id = 'muffin' and ind_n.level = 2
left join market.fund_holding_current h on h.security_id = s.security_id
where ind_n.node_id is null
  and coalesce(ps.symbol, t.value) is not null
  and (s.industry_missing_at is null or s.industry_missing_at < now() - interval '30 days')
group by s.security_id, coalesce(ps.symbol, t.value)
order by best_weight desc;

grant select on market.pending_industry to service_role;
grant select on market.sector_constituents, market.fund_sector_weight
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
