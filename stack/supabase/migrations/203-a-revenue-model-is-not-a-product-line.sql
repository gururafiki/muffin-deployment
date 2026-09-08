-- A REVENUE MODEL IS NOT A PRODUCT LINE, AND THE DIFFERENCE IS WHETHER IT MAY WEIGHT A SECTOR.
--
-- Migrations 200 and 202 took `segments.comparable_concepts` from 7 to 24 by mapping commodities.
-- This is the last cheap tranche, and it exists because of a measurement worth recording.
--
-- ── THE MEASUREMENT THAT KILLED THE OBVIOUS NEXT IDEA ─────────────────────────────────────────
-- The plan was to read each filing's XBRL LABEL LINKBASE — the parser downloads every instance and
-- discards the labels — on the theory that ~9,000 unmapped business lines are unmappable only
-- because their codes are unreadable. Measured 2026-09-07 before building it, by grouping every
-- unmapped member on a filer-independent STEM and counting distinct issuers:
--
--   Reportable          185 issuers / 290 variants     License      29 issuers /  1 variant
--   AllOtherSegments    115 /   3                      Advertising  22 /  2
--   Other               103 / 133                      Subscription 19 /  1  (AndCirculation)
--   International        38 /  47                      Royalty      19 /  1
--
-- The clusters shared by many issuers are catch-alls, geographies, or STANDARD members that are
-- already perfectly readable. The filer-specific ones fragment — 185 issuers across 290 spellings —
-- so a label would let a human READ the queue faster and would not make two companies comparable,
-- because comparability needs two issuers to land on one concept and these never collide.
-- **A better name for a member does not create a shared concept.** The linkbase is therefore not
-- the unlock it looked like, and is not built.
--
-- The corollary is the useful half: the cheap wins are exactly the stems with ONE variant, because
-- one generic alias covers every filer. That is what this migration takes, and it is the end of
-- that seam — `Insurance` looks comparable at 21 issuers and is 18 different filer-specific
-- spellings, so it is not a row here.
--
-- ── WHY TWO KINDS OF CONCEPT, DISTINGUISHED BY `node_id` ──────────────────────────────────────
-- Read the issuers rather than the counts and these split cleanly in two:
--
--   PRODUCT CATEGORIES, which are what a company SELLS:
--     us-gaap:FoodAndBeverageMember  Hyatt, Host Hotels, Caesars, Chipotle, Bloomin' Brands —
--                                    hospitality F&B revenue, a coherent line across hotels and
--                                    restaurants.
--     us-gaap:AdvertisingMember      Fox, AMC Networks, iQIYI, fuboTV, IAC, Angi. Mapped to a NEW
--                                    generic `advertising`, deliberately NOT `digital-advertising`
--                                    — Fox and AMC sell television advertising. Migration 145's
--                                    Amazon-scoped `digital-advertising` alias still wins for
--                                    Amazon, because the serving layer sorts a scoped alias first.
--
--   REVENUE MODELS, which are how a company CHARGES:
--     us-gaap:LicenseMember          ACI Worldwide, GitLab, Guidewire AND Axsome, BioCryst, Enanta
--     us-gaap:RoyaltyMember          ARM, Biogen, Alnylam AND H&R Block
--     us-gaap:SubscriptionAndCirculationMember  CrowdStrike, DocuSign, HubSpot, GitLab
--
-- The second group gets **`node_id` NULL**, and that is the load-bearing part. `node_id` pins a
-- concept to a level-1 sector and `derive_segment_classification()` uses it to WEIGHT a security's
-- sector — so pinning `royalties` anywhere would push H&R Block toward pharmaceuticals and ARM
-- toward whatever the majority happened to be. Migration 145 already established that a concept
-- with no node is legitimate and simply cannot weight a classification, which is precisely the
-- behaviour a monetisation form needs. Naming them `*-revenue` keeps them from being read as
-- product lines by anything that lists concepts.

\set ON_ERROR_STOP on

insert into market.segment_concept (code, name, node_id)
select v.code, v.name, tn.node_id
from (values
  ('advertising',       'Advertising',       'communication-services'),
  ('food-and-beverage', 'Food and beverage', 'consumer-discretionary')
) as v(code, name, sector)
join market.taxonomy_node tn
  on tn.taxonomy_id = 'muffin' and tn.level = 1 and tn.code = v.sector
on conflict (code) do update set name = excluded.name, node_id = excluded.node_id;

-- NULL node on purpose — see the header. `do update` sets it back to null if an earlier apply or a
-- hand edit ever gave one of these a sector, because that would silently start weighting.
insert into market.segment_concept (code, name, node_id) values
  ('licensing-revenue',    'Licensing revenue',    null),
  ('royalty-revenue',      'Royalty revenue',      null),
  ('subscription-revenue', 'Subscription revenue', null)
on conflict (code) do update set name = excluded.name, node_id = excluded.node_id;

-- Generic (null security_id): every one is a STANDARD member naming a category or a charging model
-- rather than a role, so it means the same thing in every filing that uses it. Contrast
-- `us-gaap:ProductMember` and `us-gaap:ServiceMember`, which migration 145 scopes per CIK.
-- `on conflict do nothing` with NO target — segment_alias uses two PARTIAL unique indexes.
insert into market.segment_alias (member_code, concept_code, security_id)
select v.member_code, v.concept_code, null::uuid
from (values
  ('us-gaap:AdvertisingMember',                'advertising'),
  ('us-gaap:FoodAndBeverageMember',            'food-and-beverage'),
  ('us-gaap:LicenseMember',                    'licensing-revenue'),
  ('us-gaap:RoyaltyMember',                    'royalty-revenue'),
  ('us-gaap:SubscriptionAndCirculationMember', 'subscription-revenue')
) as v(member_code, concept_code)
on conflict do nothing;

notify pgrst, 'reload schema';
