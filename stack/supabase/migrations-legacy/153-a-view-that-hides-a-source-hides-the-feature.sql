-- A VIEW THAT HIDES A SOURCE HIDES THE FEATURE, AND A 30-DAY TTL ON A DAILY JOB RUNS MONTHLY.
--
-- Two defects, both found by reading production after a deploy rather than by any test.
--
-- 1. `security_industries` FILTERED `taxonomy_id = 'muffin'`.
--
--    It was written in migration 143, when muffin was the only populated taxonomy. Migrations 151
--    and 152 then added SIC and Wikidata — the two sources whose whole point is to be a SECOND
--    opinion — and the view that exists to serve "every classification a security carries" silently
--    excluded both. Measured live: 36 SIC classifications stored and correct (Amazon is
--    RETAIL-CATALOG & MAIL-ORDER HOUSES, a bank is NATIONAL COMMERCIAL BANKS), and the view
--    returned none of them. Correct data that nothing could read, which this schema has shipped
--    before.
--
--    `taxonomy_id` is now a COLUMN rather than a filter, so a caller chooses. The muffin taxonomy
--    is still what `security_current` resolves for a page header; this is the whole picture.
--
-- 2. `derive-classifications` CARRIES A 30-DAY TTL AND A DAILY CRON.
--
--    So it self-skips 29 days in 30 — measured directly: an ordinary invocation returned
--    `{"skipped": true, "reason": "fresh or in flight"}` and only `force: true` would run it. That
--    was tolerable when it derived sector membership from fund holdings, which changes quarterly.
--    It is not tolerable now: migrations 143 and 151 attached the weighted segment classification
--    and the SIC link to the same resource, and a company's segments are re-parsed continuously.
--    A monthly refresh would leave a weight derived from a filing that has since been superseded.
--
--    The TTL moves to 12 hours, which is what makes the daily job it already has actually run. Same
--    shape as the fix for `security-segments`, whose five-minute job was fighting a ten-minute TTL.

drop view if exists market.security_industries;
create view market.security_industries as
select
  st.security_id,
  tn.taxonomy_id,
  tn.node_id,
  tn.code,
  tn.name,
  tn.level,
  parent.code as parent_code,
  parent.name as parent_name,
  st.source_code,
  ds.priority   as source_priority,
  st.weight,
  st.as_of
from market.security_taxonomy st
join market.taxonomy_node tn on tn.node_id = st.node_id
left join market.taxonomy_node parent on parent.node_id = tn.parent_id
join market.data_source ds on ds.code = st.source_code;

comment on view market.security_industries is
  'EVERY classification a security carries, across EVERY taxonomy, with its source, that source''s priority and — where the classification is derived from disclosed segments — its weight. `taxonomy_id` is a column, not a filter: muffin is what `security_current` resolves for a page header, while SIC and Wikidata exist precisely to disagree with it.';

grant select on market.security_industries to anon, authenticated, service_role;

notify pgrst, 'reload schema';
