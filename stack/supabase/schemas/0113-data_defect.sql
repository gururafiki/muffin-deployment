do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'data_defect';
  if k = 'm' then execute 'drop materialized view if exists market.data_defect cascade';
  elsif k = 'v' then execute 'drop view if exists market.data_defect cascade';
  end if;
end $$;
create view market.data_defect as
SELECT 'placeholder_cusip'::text AS defect,
    count(*) AS n,
    'security_identifier rows with the all-zero CUSIP placeholder'::text AS detail
   FROM market.security_identifier
  WHERE security_identifier.kind_code = 'cusip'::text AND security_identifier.value = '000000000'::text
UNION ALL
 SELECT 'placeholder_isin'::text AS defect,
    count(*) AS n,
    'security_identifier rows with the all-zero ISIN placeholder'::text AS detail
   FROM market.security_identifier
  WHERE security_identifier.kind_code = 'isin'::text AND security_identifier.value = '000000000000'::text
UNION ALL
 SELECT 'duplicate_constituents'::text AS defect,
    COALESCE(sum(q.rows_ - q.distinct_), 0::numeric) AS n,
    'sector_constituents rows beyond one per security, across ALL sectors'::text AS detail
   FROM ( SELECT sector_constituents.sector_id,
            count(*) AS rows_,
            count(DISTINCT sector_constituents.security_id) AS distinct_
           FROM market.sector_constituents
          GROUP BY sector_constituents.sector_id) q
UNION ALL
 SELECT 'returns_at_minus_100'::text AS defect,
    count(*) AS n,
    'performance rows at exactly -100% — a zero close became a total loss'::text AS detail
   FROM market.performance
  WHERE performance.scope = 'instrument'::text AND performance.change_pct = '-100'::integer::numeric
UNION ALL
 SELECT 'frozen_series'::text AS defect,
    count(*) AS n,
    'symbols whose FRESH refresh is 0.00% on every period it produced (3+ periods)'::text AS detail
   FROM ( SELECT performance.scope_id
           FROM market.performance
          WHERE performance.scope = 'instrument'::text AND performance.as_of > (now() - '2 days'::interval)
          GROUP BY performance.scope_id
         HAVING count(*) FILTER (WHERE performance.change_pct = 0::numeric) >= 3 AND count(*) FILTER (WHERE performance.change_pct IS NOT NULL AND performance.change_pct <> 0::numeric) = 0) q
UNION ALL
 SELECT 'contradicted_negative_cache'::text AS defect,
    count(*) AS n,
    'securities marked as having no returns while holding recent bars that MOVE'::text AS detail
   FROM market.security s
  WHERE s.performance_missing_at IS NOT NULL AND (( SELECT count(DISTINCT p.close) AS count
           FROM market.security_price p
          WHERE p.security_id = s.security_id AND p.date > (CURRENT_DATE - 30))) > 1 AND (EXISTS ( SELECT 1
           FROM market.security_price p
          WHERE p.security_id = s.security_id AND p.date > (CURRENT_DATE - 7)))
UNION ALL
 SELECT 'country_with_no_symbols'::text AS defect,
    count(*) AS n,
    'countries with 20+ equities and not one provider symbol'::text AS detail
   FROM ( SELECT s.country_iso2
           FROM market.security s
          WHERE s.security_type_code = 'equity'::text AND s.country_iso2 IS NOT NULL
          GROUP BY s.country_iso2
         HAVING count(*) >= 20 AND NOT (EXISTS ( SELECT 1
                   FROM market.security s2
                  WHERE s2.country_iso2 = s.country_iso2 AND ((EXISTS ( SELECT 1
                           FROM market.security_provider_symbol sp
                          WHERE sp.security_id = s2.security_id)) OR (EXISTS ( SELECT 1
                           FROM market.security_identifier i
                          WHERE i.security_id = s2.security_id AND i.kind_code = 'ticker'::text)))))) q
UNION ALL
 SELECT 'queued_but_already_done'::text AS defect,
    count(*) AS n,
    'securities in pending_industry that already have a level-2 industry'::text AS detail
   FROM market.pending_industry pi
  WHERE (EXISTS ( SELECT 1
           FROM market.security_taxonomy st
             JOIN market.taxonomy_node tn ON tn.node_id = st.node_id
          WHERE st.security_id = pi.security_id AND tn.level = 2))
UNION ALL
 SELECT 'extreme_1y_returns'::text AS defect,
    count(*) AS n,
    'GAUGE not an invariant: 1y returns >= +1000%, expected non-zero and stable'::text AS detail
   FROM market.performance
  WHERE performance.scope = 'instrument'::text AND performance.period = '1y'::text AND performance.change_pct >= 1000::numeric;
