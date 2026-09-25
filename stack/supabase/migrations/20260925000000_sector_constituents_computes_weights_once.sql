-- `sector_constituents` computes the sector funds' weights ONCE, not once per constituent.
--
-- The sector page's stock list answered `57014 canceling statement due to statement timeout` for
-- every reader. Measured 2026-09-25: the app's own query (Information Technology, 20 rows) took
-- 14.2 s against anon's 3 s and authenticated's 8 s, and market-verify had been failing on the same
-- view since about 09-08.
--
-- THE CAUSE IS A LATERAL OVER A VIEW WITH AN AGGREGATE IN IT. The weight was a per-constituent
-- `LEFT JOIN LATERAL ( ... from market.fund_holding_current ... limit 1)`, and
-- `fund_holding_current` finds each fund's latest filing with a `group by fund_id` over ALL of
-- `fund_holding`. Inside the lateral the planner re-ran that aggregate per constituent: 1,691 loops
-- x 44,445 index entries = 75M reads, 9 ms a loop. It grew with the holdings history the N-PORT lane
-- keeps adding, which is why it crossed the timeout without anything changing here. Fifth
-- occurrence of the shape after `fund_sector_weight`, `security_facets`, `price_series` and
-- `security_disclosure`.
--
-- The weights are now one MATERIALIZED CTE: every tracked fund's current holdings, computed once,
-- hash-joined on (security, sector). Measured on production data before shipping: the page's query
-- 14,176 ms -> 129 ms, the Korean-financials country drill-down 102 ms, the whole view (11,957 rows)
-- 425 ms. The result is IDENTICAL, 0 rows different in either direction for Information Technology,
-- and that holds by construction:
--   * no `represents_code` has more than one tracked fund (checked: none), and
--   * `fund_holding`'s key is (fund_id, security_id, as_of),
-- so the lateral's unordered `limit 1` could only ever see one row. The `distinct on ... weight
-- desc` below is a guard for the day a second fund represents a sector, not a behaviour change.
--
-- `fund_holding_current` itself is left alone: its other readers take it whole (the Markets donut,
-- 185 ms as anon), where one aggregate is the cheap plan. Only a per-row reader pays for it, and this
-- was the only one.
--
-- Same columns, same order, same types, so `create or replace` keeps the grants and the dependents.
-- One dependent, `data_defect`, reads this view WHOLE (its `duplicate_constituents` row) and was
-- measured at 53 s on 2026-09-12. How much of that was this lateral is to be measured once this lands,
-- not assumed.

create or replace view market.sector_constituents as
with sector_weight as materialized (
  select distinct on (tf.represents_code, h.security_id)
         tf.represents_code,
         h.security_id,
         h.weight,
         h.market_value,
         h.as_of,
         fi.value as fund_symbol
    from market.fund_holding_current h
    join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
    join market.tracked_fund tf on tf.symbol = fi.value
   order by tf.represents_code, h.security_id, h.weight desc nulls last
)
select distinct on (tn.code, s.security_id)
       tn.code as sector_id,
       s.security_id,
       s.name,
       sym.symbol,
       coalesce(s.provider_country_iso2, s.country_iso2) as country_iso2,
       ind.name as industry,
       h.weight,
       h.fund_symbol,
       s.market_cap,
       s.currency_code,
       h.market_value,
       h.as_of
  from market.security_taxonomy st
  join market.taxonomy_node tn
    on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
  join market.data_source ds on ds.code = st.source_code
  join market.security s on s.security_id = st.security_id
  left join market.security_symbol sym on sym.security_id = s.security_id
  left join lateral (
    select n.name
      from market.security_taxonomy st2
      join market.taxonomy_node n
        on n.node_id = st2.node_id and n.taxonomy_id = 'muffin' and n.level = 2
       and n.parent_id = tn.node_id
     where st2.security_id = s.security_id
     limit 1
  ) ind on true
  left join sector_weight h on h.security_id = s.security_id and h.represents_code = tn.code
 order by tn.code, s.security_id, ds.priority desc, st.as_of desc;
