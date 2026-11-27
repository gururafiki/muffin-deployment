-- A COMPANY IS SERVED ONLY ITS NEWEST YEAR (Phase 6c step 6 follow-up; the user's decision,
-- 2026-11-27).
--
-- WHY. `security_segment_current` served every axis at that axis's own newest period, so a company
-- that changed how it discloses kept its old axes on the page beside the new ones. Rendering SF
-- Holding after the China note went live (muffin-ingest#212) showed its page leading with FY 2016
-- product and region splits from its main tables, while its 2025 operating segments sat behind a
-- tab. Measured on the spine 2026-11-27: a company is served an axis over a year older than its
-- newest split for 288 securities (srt: axes), 209 (CNINFO), 138 (us-gaap:) and 90 (ifrs-full:).
-- It predates the note; the note made it visible.
--
-- THE RULE. Within the regulator a company is served from (20261127160000), only axes whose newest
-- annual period is the company's newest are served. `chosen` already carries `source_newest`, the
-- newest period across that regulator's axes, so the rule is one more predicate on the filter that
-- is applied last, after every window, and cannot change how anything beneath it is joined.
-- `security_segment_detail` follows: a cross-tab is served only at a period `current` serves.
-- Older rows stay stored; nothing is deleted.
--
-- COST, accepted with the decision: a filer that drops a split in its newest year (a geography
-- table it stopped printing) loses that split from the page until it reports one again.
--
-- `create or replace`: the columns are unchanged, so the grants and the spine built on `current`
-- stay. Guarded by tests/a-company-is-served-only-its-newest-year.sql.

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
         SELECT q.security_id,
            q.source_code,
            q.axis,
            q.member_code,
            q.currency_code,
            q.period_ending,
            q.accession_number,
            q.reconciled_to,
            q.revenue,
            q.operating_income,
            q.capital_expenditure,
            q.depreciation,
            q.cost_of_revenue,
            max(q.period_ending) OVER (PARTITION BY q.security_id, q.source_code) AS source_newest,
            ds.priority AS source_priority
           FROM pivoted q
             LEFT JOIN market.data_source ds ON ds.code = q.source_code
        ), chosen AS (
         SELECT r.security_id,
            r.source_code,
            r.axis,
            r.member_code,
            r.currency_code,
            r.period_ending,
            r.accession_number,
            r.reconciled_to,
            r.revenue,
            r.operating_income,
            r.capital_expenditure,
            r.depreciation,
            r.cost_of_revenue,
            r.source_newest,
            r.source_priority,
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
  WHERE p.source_rank = 1 AND p.period_ending = p.source_newest;

create or replace view market.security_segment_detail as
WITH newest AS (
         SELECT g.security_id,
            g.source_code,
            g.parent_axis,
            g.parent_member,
            g.axis,
            max(g.period_ending) AS period_ending
           FROM market.security_segment_latest g
          WHERE g.partition_id = 1 AND g.period_type = 'annual'::text AND g.parent_member IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM market.security_segment_current c_1
                  WHERE c_1.security_id = g.security_id AND c_1.source_code = g.source_code AND c_1.period_ending = g.period_ending))
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
