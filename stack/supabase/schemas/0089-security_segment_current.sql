do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_segment_current';
  if k = 'm' then execute 'drop materialized view if exists market.security_segment_current cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_segment_current cascade';
  end if;
end $$;
create view market.security_segment_current as
WITH newest AS (
         SELECT g.security_id,
            g.axis,
            max(g.period_ending) AS period_ending
           FROM market.security_segment_latest g
          WHERE g.partition_id = 1 AND g.period_type = 'annual'::text AND g.parent_member IS NULL
          GROUP BY g.security_id, g.axis
        ), latest AS (
         SELECT DISTINCT ON (g.security_id, g.axis, g.member_code, g.metric_code) g.security_id,
            g.axis,
            g.member_code,
            g.metric_code,
            g.value,
            g.currency_code,
            g.period_ending,
            g.accession_number,
            g.reconciled_to
           FROM market.security_segment_latest g
             JOIN newest n ON n.security_id = g.security_id AND n.axis = g.axis AND n.period_ending = g.period_ending
          WHERE g.partition_id = 1 AND g.period_type = 'annual'::text AND g.parent_member IS NULL
          ORDER BY g.security_id, g.axis, g.member_code, g.metric_code, g.period_ending DESC
        ), pivoted AS (
         SELECT l.security_id,
            l.axis,
            l.member_code,
            max(l.currency_code) AS currency_code,
            max(l.period_ending) AS period_ending,
            max(l.accession_number) AS accession_number,
            max(l.reconciled_to) AS reconciled_to,
            max(l.value) FILTER (WHERE l.metric_code = 'revenue'::text) AS revenue,
            max(l.value) FILTER (WHERE l.metric_code = 'operating_income'::text) AS operating_income,
            max(l.value) FILTER (WHERE l.metric_code = 'capital_expenditure'::text) AS capital_expenditure,
            max(l.value) FILTER (WHERE l.metric_code = 'depreciation'::text) AS depreciation,
            max(l.value) FILTER (WHERE l.metric_code = 'cost_of_revenue'::text) AS cost_of_revenue
           FROM latest l
          GROUP BY l.security_id, l.axis, l.member_code
        )
 SELECT p.security_id,
    p.axis,
    COALESCE(sm.kind, a.kind) AS kind,
    p.member_code,
    c.code AS concept_code,
    c.name AS concept_name,
    p.revenue,
    p.operating_income,
    p.capital_expenditure,
    p.depreciation,
    p.cost_of_revenue,
    ast.value AS total_assets,
        CASE
            WHEN p.revenue IS NOT NULL AND p.revenue <> 0::numeric THEN round(100::numeric * p.operating_income / p.revenue, 2)
            ELSE NULL::numeric
        END AS operating_margin_pct,
        CASE
            WHEN p.revenue IS NOT NULL AND p.revenue <> 0::numeric AND p.cost_of_revenue IS NOT NULL THEN round(100::numeric * (p.revenue - p.cost_of_revenue) / p.revenue, 2)
            ELSE NULL::numeric
        END AS gross_margin_pct,
        CASE
            WHEN p.depreciation IS NOT NULL AND p.depreciation <> 0::numeric THEN round(p.capital_expenditure / p.depreciation, 2)
            ELSE NULL::numeric
        END AS capex_to_depreciation,
        CASE
            WHEN ast.value IS NOT NULL AND ast.value <> 0::numeric THEN round(100::numeric * p.operating_income / ast.value, 2)
            ELSE NULL::numeric
        END AS return_on_segment_assets_pct,
    round(100::numeric * p.revenue / NULLIF(sum(p.revenue) OVER (PARTITION BY p.security_id, p.axis), 0::numeric), 2) AS revenue_share_pct,
    p.currency_code,
    p.period_ending,
    p.accession_number,
    p.reconciled_to,
    sm.country_iso2,
    sm.label AS member_label,
    lla.value AS long_lived_assets,
    gw.value AS goodwill
   FROM pivoted p
     CROSS JOIN LATERAL ( SELECT ax.kind
           FROM market.segment_axis ax
          WHERE ax.axis = p.axis
          ORDER BY ax.priority DESC, ax.taxonomy
         LIMIT 1) a
     LEFT JOIN market.segment_member sm ON sm.member_code = p.member_code
     LEFT JOIN LATERAL ( SELECT g.value
           FROM market.security_segment_latest g
          WHERE g.security_id = p.security_id AND g.axis = p.axis AND g.member_code = p.member_code AND g.metric_code = 'total_assets'::text AND g.period_type = 'instant'::text AND g.partition_id = 1 AND g.parent_member IS NULL AND g.period_ending <= p.period_ending
          ORDER BY g.period_ending DESC
         LIMIT 1) ast ON true
     LEFT JOIN LATERAL ( SELECT g.value
           FROM market.security_segment_latest g
          WHERE g.security_id = p.security_id AND g.axis = p.axis AND g.member_code = p.member_code AND g.metric_code = 'long_lived_assets'::text AND g.period_type = 'instant'::text AND g.partition_id = 1 AND g.parent_member IS NULL AND g.period_ending <= p.period_ending
          ORDER BY g.period_ending DESC
         LIMIT 1) lla ON true
     LEFT JOIN LATERAL ( SELECT g.value
           FROM market.security_segment_latest g
          WHERE g.security_id = p.security_id AND g.axis = p.axis AND g.member_code = p.member_code AND g.metric_code = 'goodwill'::text AND g.period_type = 'instant'::text AND g.partition_id = 1 AND g.parent_member IS NULL AND g.period_ending <= p.period_ending
          ORDER BY g.period_ending DESC
         LIMIT 1) gw ON true
     LEFT JOIN LATERAL ( SELECT al_1.concept_code
           FROM market.segment_alias al_1
          WHERE al_1.member_code = p.member_code AND (al_1.security_id = p.security_id OR al_1.security_id IS NULL)
          ORDER BY (al_1.security_id IS NOT NULL) DESC
         LIMIT 1) al ON true
     LEFT JOIN market.segment_concept c ON c.code = al.concept_code;
