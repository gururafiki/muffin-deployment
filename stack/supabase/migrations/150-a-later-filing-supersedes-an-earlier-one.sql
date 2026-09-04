-- A LATER FILING SUPERSEDES AN EARLIER ONE FOR THE SAME PERIOD, AND MEMBER CODES ARE RENAMED.
--
-- FOUND BY THE GUARD ON ITS FIRST PRODUCTION READ, which is what that read is for. Six splits
-- failed to reconcile — ratios 1.01 to 1.61 — and every one belonged to a foreign private issuer.
--
-- ASML's FY2022 revenue is EUR 21,173,400,000 and the stored split summed to **34,114,800,000**.
-- Neither the parser nor the filings were wrong. An annual report carries three years of
-- comparatives, so FY2022 appears in the FY2022 20-F *and* the FY2023 one — and **ASML renamed its
-- member codes in between**:
--
--     asml:EuvMember                  7,045,300,000  (20-F filed 2023)
--     asml:NXEMember                  7,045,300,000  (20-F filed 2024) — the same line
--     asml:ArfImmersionMember         5,236,500,000  (2023)
--     asml:ArfiMember                 5,236,500,000  (2024) — the same line
--     asml:MetrologyandinspectionMember / asml:MetrologyAndInspectionMember — differ only in CASE
--
-- `security_segment` is keyed on the member code, so the two spellings are two rows and both
-- survive. Each filing's own split reconciles perfectly; reading them TOGETHER unions two complete
-- splits of the same period and counts the company one-and-a-half times.
--
-- THE PARSER CANNOT FIX THIS — it sees one document at a time and is right about it. Nor can a
-- dedupe: the values are identical but the codes are not, and "same value" is not evidence of the
-- same line. The fix is that a period's split belongs to ONE filing, and the newest one wins.
--
-- Deliberately NOT a delete. `tests/an-older-filing-must-not-overwrite-a-newer-one.sql` already
-- names this family, and an upsert cannot retract: keeping both filings' rows means a restatement
-- stays visible and the choice is made where it can be re-made — in the view.

drop view if exists market.security_segment_latest cascade;
create view market.security_segment_latest as
with ranked as (
  select
    g.*,
    f.filing_date,
    -- DENSE_RANK, NOT ROW_NUMBER: a whole filing's split wins together. Ranking rows individually
    -- would take the newest row per MEMBER and reassemble a split that no filing ever reported —
    -- mixing `EuvMember` from 2023 with `ArfiMember` from 2024 and double counting anyway.
    dense_rank() over (
      partition by g.security_id, g.axis, g.metric_code, g.period_type, g.period_ending
      order by f.filing_date desc nulls last, g.accession_number desc
    ) as filing_rank
  from market.security_segment g
  -- LEFT, so a row whose accession is not in `security_filing` is still served rather than
  -- silently dropped. `nulls last` above then puts it behind any dated filing.
  left join market.security_filing f
    on f.security_id = g.security_id and f.accession_number = g.accession_number
)
select
  security_id, axis, member_code, parent_axis, parent_member, metric_code,
  period_type, period_ending, period_start, value, currency_code, partition_id,
  -- LISTED EXPLICITLY, and that is why the column had to be declared in migration 141 rather than
  -- in the file that introduced it: a view names its columns at creation time (`select *` freezes
  -- them just the same), so a reader asking for a column this list omits gets a **400**, not a
  -- null. The reconciliation guard could not run at all until this line existed.
  reconciled_to,
  accession_number, filing_date, source_code, as_of
from ranked
where filing_rank = 1;

comment on view market.security_segment_latest is
  'One filing per (security, axis, metric, period) — the most recently filed. An annual report carries three years of comparatives, so a period appears in several filings, and filers RENAME member codes between them (ASML''s EuvMember became NXEMember). Reading the raw table unions two complete splits of the same period and counts the company twice. Everything that serves segments reads this, not `security_segment`.';

grant select on market.security_segment_latest to anon, authenticated, service_role;

-- ── Both serving views now read the superseded-aware source ───────────────────────────────────
-- ── `security_segment_current` IS DEFINED ONCE, IN MIGRATION 157 ──────────────────────────────
-- It used to be defined here too. FIVE migrations (141, 148, 149, 150, 157) each carried a
-- `create view` for it with a different column list, and `create or replace view` can only APPEND
-- columns — so the earliest definer could never impose the latest one's shape and had to DROP,
-- taking its dependents with it. That is a real window on EVERY deploy, roughly sixteen files
-- wide, in which the view and the segment spine do not exist. Tolerable only while nothing
-- user-facing read them, which stopped being true when the stock page began drawing business
-- lines. The header above still records WHY the view carries what it carries; only the DDL moved.


drop view if exists market.security_segment_detail;
create view market.security_segment_detail as
with newest as (
  -- ONE PERIOD PER NESTED GROUP, chosen before any member is looked at — the same defect and the
  -- same fix as `security_segment_current`; see the note in migration 157. 56 of 242 nested groups
  -- spanned more than one period in production, which makes a child's share OF ITS PARENT wrong:
  -- the denominator is a sum over years the parent never reported together.
  select g.security_id, g.parent_axis, g.parent_member, g.axis,
         max(g.period_ending) as period_ending
  from market.security_segment_latest g
  where g.partition_id = 1 and g.period_type = 'annual' and g.parent_member is not null
  group by g.security_id, g.parent_axis, g.parent_member, g.axis
),
latest as (
  select distinct on (g.security_id, g.parent_member, g.axis, g.member_code, g.metric_code)
    g.security_id, g.parent_axis, g.parent_member, g.axis, g.member_code, g.metric_code,
    g.value, g.currency_code, g.period_ending
  from market.security_segment_latest g
  join newest n
    on n.security_id = g.security_id and n.parent_axis is not distinct from g.parent_axis
   and n.parent_member = g.parent_member and n.axis = g.axis
   and n.period_ending = g.period_ending
  where g.partition_id = 1 and g.period_type = 'annual' and g.parent_member is not null
  order by g.security_id, g.parent_member, g.axis, g.member_code, g.metric_code,
           g.period_ending desc
),
pivoted as (
  select
    l.security_id, l.parent_axis, l.parent_member, l.axis, l.member_code,
    max(l.currency_code) as currency_code,
    max(l.period_ending) as period_ending,
    max(l.value) filter (where l.metric_code = 'revenue')          as revenue,
    max(l.value) filter (where l.metric_code = 'operating_income') as operating_income
  from latest l
  group by l.security_id, l.parent_axis, l.parent_member, l.axis, l.member_code
)
select
  p.security_id, p.parent_axis, p.parent_member, p.axis, p.member_code,
  c.code as concept_code, c.name as concept_name,
  p.revenue, p.operating_income,
  round(100 * p.revenue
        / nullif(sum(p.revenue) over (partition by p.security_id, p.parent_member, p.axis), 0), 2)
    as share_of_parent_pct,
  p.currency_code, p.period_ending
from pivoted p
left join lateral (
  select al.concept_code from market.segment_alias al
  where al.member_code = p.member_code
    and (al.security_id = p.security_id or al.security_id is null)
  order by (al.security_id is not null) desc limit 1
) al on true
left join market.segment_concept c on c.code = al.concept_code;

comment on view market.security_segment_detail is
  'Product lines disclosed WITHIN a reportable segment — Alphabet''s Search, YouTube, Network and Subscriptions inside Google Services. Their share is OF THE PARENT, not of the company. Never sum these beside `security_segment_current`.';

grant select on market.security_segment_detail
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
