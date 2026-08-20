-- Listings we know of but do not hold — IDEMPOTENT.
--
-- The exchange directory reached 14,760 rows and NOTHING READ IT: search was built over
-- `security_current`, which is the 10,060 securities the tracked funds hold. So a company listed
-- on an exchange we enumerate but held by no tracked fund was still unreachable — which is the
-- exact limitation the directory was built to remove.
--
-- This is the other half: the listings that are NOT already securities, so search can offer them
-- and `promote-listing` can pull one into the universe on demand.
--
-- Joined on FIGI because that is the only key the directory has — `/v3/filter` returns no ISIN,
-- which is why `security-local-symbols` stores the composite FIGI as it resolves.

create or replace view market.untracked_listing as
select
  l.figi,
  l.composite_figi,
  l.exch_code,
  l.ticker,
  l.name,
  l.country_iso2,
  l.provider_symbol
from market.exchange_listing l
left join market.security_identifier si
  on si.kind_code = 'figi' and si.value = l.composite_figi
where si.security_id is null
  and l.name is not null;

grant select on market.untracked_listing to anon, authenticated, service_role;

notify pgrst, 'reload schema';

-- ── name the fund a weight is a share OF ─────────────────────────────────────
-- The pages say "61% of fund" without saying which fund, so the number is unattributable: a
-- reader cannot tell whether it is a share of the country's ETF, the sector SPDR, or something
-- else. The views already join the fund to find the weight — they simply did not return it.

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
  h.fund_symbol,
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
  select h.weight, h.market_value, h.as_of, fi.value as fund_symbol
  from market.fund_holding_current h
  join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf on tf.symbol = fi.value and tf.represents_code = tn.code
  where h.security_id = s.security_id
  limit 1
) h on true
order by tn.code, s.security_id, ds.priority desc, st.as_of desc;

-- The country view gains the same: which fund the weighted mean was taken over.
drop view if exists market.country_sector_performance;
create view market.country_sector_performance as
with constituent as (
  select distinct on (s.security_id)
    s.security_id,
    s.country_iso2,
    tn.code as sector_id,
    coalesce(t.value, ps.symbol) as symbol,
    h.weight,
    tf.symbol as fund_symbol
  from market.security s
  join market.security_taxonomy st on st.security_id = s.security_id
  join market.taxonomy_node tn
    on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
  join market.data_source ds on ds.code = st.source_code
  left join market.security_identifier t
    on t.security_id = s.security_id and t.kind_code = 'ticker'
  left join market.security_provider_symbol ps
    on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
  join market.fund_holding_current h on h.security_id = s.security_id
  join market.security_identifier fi
    on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf
    on tf.symbol = fi.value and tf.kind = 'country' and tf.represents_code = s.country_iso2
  where s.country_iso2 is not null
    and s.security_type_code = 'equity'
    and h.weight > 0
    and coalesce(t.value, ps.symbol) is not null
  order by s.security_id, ds.priority desc, st.as_of desc
)
select
  c.country_iso2,
  c.sector_id,
  p.period,
  round(sum(c.weight * p.change_pct) / nullif(sum(c.weight), 0), 4) as change_pct,
  count(*) as constituents,
  round(sum(c.weight), 4) as weight_covered,
  min(c.fund_symbol) as fund_symbol,
  max(p.as_of) as as_of
from constituent c
join market.performance p
  on p.scope = 'instrument' and p.scope_id = c.symbol
group by c.country_iso2, c.sector_id, p.period;

grant select on market.sector_constituents, market.country_sector_performance
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
