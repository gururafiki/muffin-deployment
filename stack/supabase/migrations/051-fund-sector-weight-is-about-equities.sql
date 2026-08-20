-- `fund_sector_weight` times out for the app — IDEMPOTENT.
--
-- Measured 2026-08-13 against production:
--
--   anon    -> 500 in 3.2s   {"code":"57014","message":"canceling statement due to statement timeout"}
--   service -> 200 in 7.2s
--
-- Not an RLS or grant problem, which is what the failing check's wording suggested and what I
-- assumed first: the view simply takes ~7s and anon's statement timeout is 3s, so the role that
-- fails is the role with the shorter leash. `muffin-ui`'s `use-fund-sector-weights.ts` reads it with
-- the ANON key, so the sector donut has been failing in the app, not merely in CI.
--
-- It got slow because the universe tripled today: `fund_holding` went to 39,886 rows, and the
-- taxonomy it joins went to ~19,000 as industries were classified.
--
-- Two changes, each of which is a correctness fix that happens to also cut the work:
--
-- 1. EQUITIES ONLY. A *sector* weight over bond holdings is not a slow answer, it is a meaningless
--    one — `AGG` reported a single row, `unclassified`, at 100%. 21,371 of the 39,886 holdings are
--    equity, so this is also 46% less to aggregate.
--
-- 2. LEVEL 1 ONLY. The `classified` CTE joined `taxonomy_node` with no level restriction, so every
--    level-2 industry row was a candidate for a security's "sector" and `distinct on` picked
--    between them by source priority — which is not a rule about levels at all. It happened to
--    return only real sectors while industries were rare; there are now 5,673 of them. That is a
--    latent wrong-answer bug independent of the timeout, and it doubles the CTE.
--
-- `fund_country_weight` is deliberately NOT changed: a country weight over a bond IS meaningful
-- (sovereign and corporate issuers have countries), and it answers anon fine.

drop view if exists market.fund_sector_weight;
create view market.fund_sector_weight as
with classified as (
  -- One SECTOR per security, chosen the same way, before any summing.
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
join market.security s on s.security_id = h.security_id and s.security_type_code = 'equity'
left join classified c on c.security_id = h.security_id
where h.security_id <> h.fund_id
group by fi.value, coalesce(c.code, 'unclassified');

comment on view market.fund_sector_weight is
  'Sector weights within a fund, over its EQUITY holdings only. Percentages renormalise over those holdings, so a fund that is part bonds sums to 100% across the equities it does hold — weights do not sum to 100 in the filings either (EWT sums to 110.38).';

grant select on market.fund_sector_weight to anon, authenticated, service_role;

notify pgrst, 'reload schema';
