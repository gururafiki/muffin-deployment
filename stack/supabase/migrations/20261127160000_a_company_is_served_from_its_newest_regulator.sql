-- A COMPANY IS SERVED FROM ITS NEWEST REGULATOR, AND A REGULATOR IT LEFT STAYS STORED.
--
-- WHY. `security_segment_current` chose the newest annual period PER AXIS, and an axis string
-- belongs to one regulator, so a company with splits from two regulators was served both side by
-- side, each at its own newest year. Measured on production 2026-11-27, three securities:
--   6857.T  Advantest           edinet FY2026-03-31 (2 axes)  beside  sec-segments FY2014-03-31 (1 axis)
--   338.HK  Sinopec Shanghai    sec-segments FY2022-12-31     beside  cninfo FY2015-12-31 (2 axes)
--   600688.SS  (the same company's A share)
-- Advantest's page therefore showed its 2014 SEC business split beside its 2026 EDINET one. The
-- EDINET history drain (ten years, started 2026-11-27) reaches every Japanese company that once
-- filed a 20-F (Canon, Kyocera, Nidec, Panasonic, Hitachi), so this grows with it.
--
-- THE RULE, DECIDED BY THE USER 2026-11-27 ("Newest regulator only"): a company serves the one
-- regulator whose newest annual placed period is the company's newest; a tie goes to the higher
-- `data_source.priority`. Every other regulator's rows stay in `security_segment` — a serving
-- choice, not a retraction.
--
-- HOW. Everything below `pivoted` is keyed by regulator as well (an IFRS axis string is shared by
-- SEC 20-F filers and DART), and the choice is a window over the pivoted rows, filtered last. A
-- shared view joined into `newest` was tried first and rejected on production's plan: the extra
-- join collapsed `newest`'s row estimate to 1, the planner put the whole of
-- `security_segment_latest` on the inner side of a nested loop, and a third parallel hash of
-- `security_filing` ran out of /dev/shm (256 MB) — the whole read is the spine's refresh.
-- A filter applied after the windows cannot change how anything beneath it is joined.
--
-- The instant laterals (total assets, long-lived assets, goodwill) are bounded by the regulator
-- too, or a company could be served one regulator's revenue beside the other's assets.
--
-- `source_code` is APPENDED to the view, so `create or replace` keeps its grants and the spine.
-- `security_segment_detail` and check_segments_reconcile.py read the choice from it rather than
-- deriving it again. The spine (`select *` when it was created) keeps its columns: nothing that
-- reads it needs the regulator, and recreating a matview drops its grants and indexes.
--
-- Guarded by tests/a-company-is-served-from-its-newest-regulator.sql.

create or replace view market.security_segment_current as
WITH newest AS (
         SELECT g.security_id,
            g.source_code,
            g.axis,
            max(g.period_ending) AS period_ending
           FROM market.security_segment_latest g
          WHERE g.partition_id = 1 AND g.period_type = 'annual'::text AND g.parent_member IS NULL
          GROUP BY g.security_id, g.source_code, g.axis
        ), latest AS (
         SELECT DISTINCT ON (g.security_id, g.source_code, g.axis, g.member_code, g.metric_code) g.security_id,
            g.source_code,
            g.axis,
            g.member_code,
            g.metric_code,
            g.value,
            g.currency_code,
            g.period_ending,
            g.accession_number,
            g.reconciled_to
           FROM market.security_segment_latest g
             JOIN newest n ON n.security_id = g.security_id AND n.source_code = g.source_code AND n.axis = g.axis AND n.period_ending = g.period_ending
          WHERE g.partition_id = 1 AND g.period_type = 'annual'::text AND g.parent_member IS NULL
          ORDER BY g.security_id, g.source_code, g.axis, g.member_code, g.metric_code, g.period_ending DESC
        ), pivoted AS (
         SELECT l.security_id,
            l.source_code,
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
          GROUP BY l.security_id, l.source_code, l.axis, l.member_code
        ), ranked AS (
         SELECT q.*,
            max(q.period_ending) OVER (PARTITION BY q.security_id, q.source_code) AS source_newest,
            ds.priority AS source_priority
           FROM pivoted q
             LEFT JOIN market.data_source ds ON ds.code = q.source_code
        ), chosen AS (
         SELECT r.*,
            dense_rank() OVER (PARTITION BY r.security_id ORDER BY r.source_newest DESC, r.source_priority DESC NULLS LAST, r.source_code) AS source_rank
           FROM ranked r
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
    gw.value AS goodwill,
    p.source_code
   FROM chosen p
     CROSS JOIN LATERAL ( SELECT ax.kind
           FROM market.segment_axis ax
          WHERE ax.axis = p.axis
          ORDER BY ax.priority DESC, ax.taxonomy
         LIMIT 1) a
     LEFT JOIN market.segment_member sm ON sm.member_code = p.member_code
     LEFT JOIN LATERAL ( SELECT g.value
           FROM market.security_segment_latest g
          WHERE g.security_id = p.security_id AND g.source_code = p.source_code AND g.axis = p.axis AND g.member_code = p.member_code AND g.metric_code = 'total_assets'::text AND g.period_type = 'instant'::text AND g.partition_id = 1 AND g.parent_member IS NULL AND g.period_ending <= p.period_ending
          ORDER BY g.period_ending DESC
         LIMIT 1) ast ON true
     LEFT JOIN LATERAL ( SELECT g.value
           FROM market.security_segment_latest g
          WHERE g.security_id = p.security_id AND g.source_code = p.source_code AND g.axis = p.axis AND g.member_code = p.member_code AND g.metric_code = 'long_lived_assets'::text AND g.period_type = 'instant'::text AND g.partition_id = 1 AND g.parent_member IS NULL AND g.period_ending <= p.period_ending
          ORDER BY g.period_ending DESC
         LIMIT 1) lla ON true
     LEFT JOIN LATERAL ( SELECT g.value
           FROM market.security_segment_latest g
          WHERE g.security_id = p.security_id AND g.source_code = p.source_code AND g.axis = p.axis AND g.member_code = p.member_code AND g.metric_code = 'goodwill'::text AND g.period_type = 'instant'::text AND g.partition_id = 1 AND g.parent_member IS NULL AND g.period_ending <= p.period_ending
          ORDER BY g.period_ending DESC
         LIMIT 1) gw ON true
     LEFT JOIN LATERAL ( SELECT al_1.concept_code
           FROM market.segment_alias al_1
          WHERE al_1.member_code = p.member_code AND (al_1.security_id = p.security_id OR al_1.security_id IS NULL)
          ORDER BY (al_1.security_id IS NOT NULL) DESC
         LIMIT 1) al ON true
     LEFT JOIN market.segment_concept c ON c.code = al.concept_code
  WHERE p.source_rank = 1;

create or replace view market.security_segment_detail as
WITH newest AS (
         SELECT g.security_id,
            g.source_code,
            g.parent_axis,
            g.parent_member,
            g.axis,
            max(g.period_ending) AS period_ending
           FROM market.security_segment_latest g
          WHERE g.partition_id = 1 AND g.period_type = 'annual'::text AND g.parent_member IS NOT NULL
            AND (EXISTS ( SELECT 1
                   FROM market.security_segment_current c
                  WHERE c.security_id = g.security_id AND c.source_code = g.source_code))
          GROUP BY g.security_id, g.source_code, g.parent_axis, g.parent_member, g.axis
        ), latest AS (
         SELECT DISTINCT ON (g.security_id, g.parent_member, g.axis, g.member_code, g.metric_code) g.security_id,
            g.parent_axis,
            g.parent_member,
            g.axis,
            g.member_code,
            g.metric_code,
            g.value,
            g.currency_code,
            g.period_ending
           FROM market.security_segment_latest g
             JOIN newest n ON n.security_id = g.security_id AND n.source_code = g.source_code AND NOT n.parent_axis IS DISTINCT FROM g.parent_axis AND n.parent_member = g.parent_member AND n.axis = g.axis AND n.period_ending = g.period_ending
          WHERE g.partition_id = 1 AND g.period_type = 'annual'::text AND g.parent_member IS NOT NULL
          ORDER BY g.security_id, g.parent_member, g.axis, g.member_code, g.metric_code, g.period_ending DESC
        ), pivoted AS (
         SELECT l.security_id,
            l.parent_axis,
            l.parent_member,
            l.axis,
            l.member_code,
            max(l.currency_code) AS currency_code,
            max(l.period_ending) AS period_ending,
            max(l.value) FILTER (WHERE l.metric_code = 'revenue'::text) AS revenue,
            max(l.value) FILTER (WHERE l.metric_code = 'operating_income'::text) AS operating_income
           FROM latest l
          GROUP BY l.security_id, l.parent_axis, l.parent_member, l.axis, l.member_code
        )
 SELECT p.security_id,
    p.parent_axis,
    p.parent_member,
    p.axis,
    p.member_code,
    c.code AS concept_code,
    c.name AS concept_name,
    p.revenue,
    p.operating_income,
    round(100::numeric * p.revenue / NULLIF(sum(p.revenue) OVER (PARTITION BY p.security_id, p.parent_member, p.axis), 0::numeric), 2) AS share_of_parent_pct,
    p.currency_code,
    p.period_ending
   FROM pivoted p
     LEFT JOIN LATERAL ( SELECT al_1.concept_code
           FROM market.segment_alias al_1
          WHERE al_1.member_code = p.member_code AND (al_1.security_id = p.security_id OR al_1.security_id IS NULL)
          ORDER BY (al_1.security_id IS NOT NULL) DESC
         LIMIT 1) al ON true
     LEFT JOIN market.segment_concept c ON c.code = al.concept_code;
