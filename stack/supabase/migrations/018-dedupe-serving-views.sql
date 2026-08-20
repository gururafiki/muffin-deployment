-- One row per security per sector, whatever the sources say — IDEMPOTENT.
--
-- `security_taxonomy` is deliberately many-to-many over SOURCES: a filing (sec-nport) and a
-- provider (yfinance) can both classify the same security, and keeping both is the point — the
-- serving view picks by `data_source.priority` instead of one silently overwriting the other.
--
-- The serving views did not do the picking. As soon as `security-profiles` ran, every US large cap
-- had BOTH rows and:
--   * `sector_constituents` returned it twice — the sector page listed "MU · Micron +624.2%"
--     twice in its movers panel, visible on the deployed site;
--   * `fund_sector_weight` summed its weight twice. The percentages still looked plausible ONLY
--     because renormalising cancels a roughly-uniform double count. That is luck: a US security
--     had two rows and a non-US one had one, so any fund mixing them would be skewed, and nothing
--     about the output said so.
--
-- A security can also legitimately carry more than one ticker (`security_identifier` is keyed on
-- (kind, value), not on security), which is a second, quieter way to duplicate a row — hence the
-- lateral limit 1 rather than a plain join.

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
  h.weight,
  h.market_value,
  h.as_of
from market.security_taxonomy st
join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin'
join market.data_source ds   on ds.code = st.source_code
join market.security s       on s.security_id = st.security_id
left join lateral (
  select i.value as symbol
  from market.security_identifier i
  where i.security_id = s.security_id and i.kind_code = 'ticker'
  order by i.value
  limit 1
) t on true
left join lateral (
  select h.weight, h.market_value, h.as_of
  from market.fund_holding_current h
  join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf on tf.symbol = fi.value and tf.represents_code = tn.code
  where h.security_id = s.security_id
  limit 1
) h on true
-- The filing wins over the provider: priority is sec-nport 300, yfinance 100.
order by tn.code, s.security_id, ds.priority desc, st.as_of desc;

drop view if exists market.fund_sector_weight;
create view market.fund_sector_weight as
with classified as (
  -- One sector per security, chosen the same way, BEFORE any summing.
  select distinct on (st.security_id) st.security_id, tn.code
  from market.security_taxonomy st
  join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin'
  join market.data_source ds   on ds.code = st.source_code
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

grant select on market.sector_constituents, market.fund_sector_weight
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
