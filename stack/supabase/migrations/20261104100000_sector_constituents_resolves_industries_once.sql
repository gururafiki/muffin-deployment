-- `sector_constituents` resolves industries ONCE, not once per constituent, and reads its symbols
-- from `symbol_security`.
--
-- market-verify read `data_defect` as anon and got `57014 canceling statement due to statement
-- timeout` on 2026-11-04 (anon's ceiling is 3 s). Measured that evening on a quiet node:
-- `data_defect` takes 0.9-1.3 s, and 0.9 s of it is ONE arm, `duplicate_constituents`, which reads
-- this view whole. GitHub has been starting the 03:30 cron 6-8 hours late, so the run lands inside
-- the SEC filer sensor's weekday tick (11:08-12:15), which writes on every chunk, and a second
-- becomes three.
--
-- THE COST IS TWO PER-ROW LOOKUPS, the shape this view already met once (#391, the weights):
--   * the industry was a `LEFT JOIN LATERAL ( ... limit 1)` per constituent: 13,058 loops, 390 ms;
--   * the symbol came from `security_symbol`, the LATERAL view every other serving view has left
--     for the indexed `symbol_security` (#437, #447).
-- The industry is now one MATERIALIZED CTE, hash-joined on (security, parent sector), and the symbol
-- comes from `symbol_security`, whose rows are exactly `security_symbol`'s rows that have a symbol,
-- one per security (measured for #447: 12,402 = 12,402, 0 differing). Only freshness differs: it is
-- refreshed with the facets.
--
-- Measured on production in a rolled-back transaction before shipping:
--   * the whole view (12,442 rows) 1,323 ms -> 218 ms;
--   * the app's query, Information Technology (1,759 rows), 153 ms -> 88 ms;
--   * the result is IDENTICAL, 0 rows different in either direction over the whole view.
--
-- ONE BEHAVIOUR CHANGE, deliberately: the lateral's `limit 1` had no order, so a security with two
-- industries under one sector was served whichever the plan reached first. The CTE orders by name.
-- No production row shows the difference (the comparison above), so it decides only future ties.
--
-- Same columns, same order, same types, so `create or replace` keeps the grants and `data_defect`.

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
), industry as materialized (
  select distinct on (st2.security_id, n.parent_id)
         st2.security_id,
         n.parent_id,
         n.name
    from market.security_taxonomy st2
    join market.taxonomy_node n
      on n.node_id = st2.node_id and n.taxonomy_id = 'muffin' and n.level = 2
   order by st2.security_id, n.parent_id, n.name
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
  join market.taxonomy_node tn on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
  join market.data_source ds on ds.code = st.source_code
  join market.security s on s.security_id = st.security_id
  left join market.symbol_security sym on sym.security_id = s.security_id
  -- THE PARENT IS PART OF THE JOIN: an industry is served only under the sector it is a child of
  -- (`tests/an-industry-belongs-to-its-sector.sql` for `security_current`).
  left join industry ind on ind.security_id = s.security_id and ind.parent_id = tn.node_id
  left join sector_weight h on h.security_id = s.security_id and h.represents_code = tn.code
 order by tn.code, s.security_id, ds.priority desc, st.as_of desc;
