-- A VOCABULARY NOBODY SEEDED CLASSIFIES NOTHING, AND A FUNCTION NOBODY CALLS CANNOT FAIL.
--
-- Migrations 141 and 143 shipped the whole segment machinery and left it INERT, in two ways this
-- schema has been caught by before:
--
--   * `market.segment_concept` and `segment_alias` were EMPTY, so `security_segment_current.
--     concept_code` was null for every row, `derive_segment_classification()` joined to nothing and
--     produced nothing, and the "can these companies be compared" panel had no rows to draw. Same
--     shape as migration 56, where a new column was added, the resource filled it correctly, and
--     production sat at **0 rows populated** because the backlog driving it was already drained.
--   * `derive_segment_classification()` was defined, granted, tested — and INVOKED BY NOTHING
--     outside its own test. "A resource that is never invoked cannot fail, and an unread view
--     cannot be wrong": `exchange-listings` was deployed, reachable and unscheduled for weeks, and
--     `untracked_listing` called 9,976 tracked companies untracked because nothing read it.
--
-- This file fixes both.
--
-- EVERY ALIAS BELOW WAS MEASURED, NOT REMEMBERED. Each member code was read out of the named
-- company's own most recent 10-K/20-F instance on 2026-08-29 by the parser that will read them in
-- production. Authoring an XBRL member code from memory is how a mapping silently matches nothing
-- for ever — and `find-the-data-source` is already a rule here because authoring reference data
-- from memory once dropped Taiwan.

-- ── The shared nouns ──────────────────────────────────────────────────────────────────────────
--
-- `node_id` is what lets a business line WEIGHT a company's classification. A concept with no node
-- is still useful — it makes the line comparable across companies — it just does not classify.
insert into market.segment_concept (code, name, node_id)
select v.code, v.name, tn.node_id
from (values
  ('cloud-infrastructure',  'Cloud infrastructure',      'information-technology'),
  ('enterprise-software',   'Enterprise software',       'information-technology'),
  ('digital-services',      'Consumer digital services', 'information-technology'),
  ('smartphones',           'Smartphones',               'information-technology'),
  ('personal-computers',    'Personal computers',        'information-technology'),
  ('tablets',               'Tablets',                   'information-technology'),
  ('wearables-accessories', 'Wearables and accessories', 'information-technology'),
  ('semiconductors',        'Semiconductors',            'information-technology'),
  ('networking-equipment',  'Networking equipment',      'information-technology'),
  ('digital-advertising',   'Digital advertising',       'communication-services'),
  ('social-platforms',      'Social platforms',          'communication-services'),
  ('gaming',                'Gaming',                    'communication-services'),
  ('consumer-subscriptions','Consumer subscriptions',    'communication-services'),
  ('online-retail',         'Online retail',             'consumer-discretionary'),
  ('marketplace-services',  'Marketplace services',      'consumer-discretionary'),
  ('automotive',            'Automotive',                'consumer-discretionary'),
  ('physical-retail',       'Physical retail',           'consumer-staples'),
  ('alcoholic-beverages',   'Alcoholic beverages',       'consumer-staples'),
  ('oil-and-gas',           'Oil and gas',               'energy'),
  ('energy-storage',        'Energy generation and storage', 'utilities'),
  ('health-insurance',      'Health insurance',          'health-care'),
  ('pharmacy-services',     'Pharmacy services',         'health-care'),
  ('health-services',       'Health services',           'health-care')
) as v(code, name, sector)
left join market.taxonomy_node tn
  on tn.taxonomy_id = 'muffin' and tn.code = v.sector and tn.level = 1
-- `do update` on the NAME and node only: this is a vocabulary, and correcting a label should
-- travel. The alias table below is where a human's judgement lives, and that one does nothing.
on conflict (code) do update set name = excluded.name, node_id = excluded.node_id;

-- ── The mappings ──────────────────────────────────────────────────────────────────────────────
--
-- ONLY COMPANY-EXTENSION MEMBERS ARE MAPPED UNSCOPED. A code carrying the filer's own prefix
-- (`amzn:`, `msft:`) is unique to that filer, so a null `security_id` is safe. The generic
-- `us-gaap:` members are NOT — `us-gaap:ServiceMember` is Apple's Services division, Amazon's
-- service revenue and Cisco's support contracts, three different businesses — so those are scoped
-- by CIK further down.
--
-- NO GEOGRAPHIC MEMBER IS MAPPED, AND THAT IS THE SUBTLE ONE. `kind` comes from the AXIS, so
-- Apple's `AmericasSegmentMember` and Amazon's `NorthAmericaSegmentMember` sit on
-- `StatementBusinessSegmentsAxis` and are typed `business` — the derivation's `kind <> 'geography'`
-- guard does NOT exclude them. What excludes them is that nobody gave them a concept. Anyone
-- extending this table must not "helpfully" map a region: it would classify Apple as whatever
-- "Americas" points at, and the arithmetic would look perfectly healthy.
insert into market.segment_alias (member_code, concept_code, security_id) values
  -- Apple
  ('aapl:IPhoneMember',                          'smartphones',           null),
  ('aapl:MacMember',                             'personal-computers',    null),
  ('aapl:IPadMember',                            'tablets',               null),
  ('aapl:WearablesHomeandAccessoriesMember',     'wearables-accessories', null),
  -- Amazon
  ('amzn:AmazonWebServicesMember',               'cloud-infrastructure',  null),
  ('amzn:AmazonWebServicesSegmentMember',        'cloud-infrastructure',  null),
  ('amzn:OnlineStoresMember',                    'online-retail',         null),
  ('amzn:ThirdPartySellerServicesMember',        'marketplace-services',  null),
  ('amzn:SubscriptionServicesMember',            'consumer-subscriptions',null),
  ('amzn:PhysicalStoresMember',                  'physical-retail',       null),
  -- Microsoft
  ('msft:IntelligentCloudMember',                'cloud-infrastructure',  null),
  ('msft:ServerProductsAndCloudServicesMember',  'cloud-infrastructure',  null),
  ('msft:ProductivityAndBusinessProcessesMember','enterprise-software',   null),
  ('msft:MicrosoftThreeSixFiveCommercialProductsAndCloudServicesMember','enterprise-software', null),
  ('msft:MicrosoftThreeSixFiveConsumerProductsAndCloudServicesMember',  'digital-services',    null),
  ('msft:DynamicsProductsAndCloudServicesMember','enterprise-software',   null),
  ('msft:EnterpriseAndPartnerServicesMember',    'enterprise-software',   null),
  ('msft:XBOXMember',                            'gaming',                null),
  ('msft:LinkedInCorporationMember',             'social-platforms',      null),
  ('msft:SearchAdvertisingMember',               'digital-advertising',   null),
  ('msft:WindowsAndDevicesMember',               'personal-computers',    null),
  -- Alphabet. Google Services is predominantly advertising; the Search / YouTube / Network split
  -- INSIDE it is tagged on two segment axes at once and is deliberately not stored — see the
  -- cross-tab note in segments.ts.
  ('goog:GoogleCloudMember',                     'cloud-infrastructure',  null),
  ('goog:GoogleServicesMember',                  'digital-advertising',   null),
  -- Nvidia
  ('nvda:ComputeAndNetworkingSegmentMember',     'semiconductors',        null),
  ('nvda:GraphicsSegmentMember',                 'semiconductors',        null),
  ('nvda:ComputeMember',                         'semiconductors',        null),
  ('nvda:NetworkingMember',                      'semiconductors',        null),
  ('nvda:GamingMember',                          'semiconductors',        null),
  ('nvda:ProfessionalVisualizationMember',       'semiconductors',        null),
  ('nvda:AutomotiveMember',                      'semiconductors',        null),
  -- Meta
  ('meta:FamilyOfAppsMember',                    'social-platforms',      null),
  ('meta:RealityLabsMember',                     'wearables-accessories', null),
  -- Tesla
  ('tsla:AutomotiveSegmentMember',               'automotive',            null),
  ('tsla:AutomotiveSalesMember',                 'automotive',            null),
  ('tsla:AutomotiveLeasingMember',               'automotive',            null),
  ('tsla:EnergyGenerationAndStorageSegmentMember','energy-storage',       null),
  ('tsla:EnergyGenerationAndStorageSalesMember', 'energy-storage',        null),
  -- UnitedHealth
  ('unh:UnitedhealthcareMember',                 'health-insurance',      null),
  ('unh:OptumrxMember',                          'pharmacy-services',     null),
  ('unh:OptumhealthMember',                      'health-services',       null),
  ('unh:OptuminsightMember',                     'health-services',       null),
  -- Walmart
  ('wmt:WalmartUSMember',                        'physical-retail',       null),
  ('wmt:WalmartInternationalMember',             'physical-retail',       null),
  ('wmt:SamsClubUSMember',                       'physical-retail',       null),
  -- Exxon
  ('xom:SalesAndOtherOperatingRevenueMember',    'oil-and-gas',           null),
  -- Diageo (ifrs-full, and a measured reminder that the parser is taxonomy-agnostic)
  ('deo:SpiritsMember',                          'alcoholic-beverages',   null),
  ('deo:BeerMember',                             'alcoholic-beverages',   null),
  ('deo:ReadyToDrinkMember',                     'alcoholic-beverages',   null)
-- NO TARGET on the conflict clause: `segment_alias` is keyed by two PARTIAL unique indexes (one
-- for scoped rows, one for generic), and a partial index is not covered by `on conflict (a,b)`.
on conflict do nothing;

-- ── The generic members, scoped by CIK ────────────────────────────────────────────────────────
--
-- `us-gaap:ServiceMember` is $109bn of Apple Services and also Cisco's support contracts, so it
-- can only be mapped per company. Matching on the CIK rather than the name because the CIK is the
-- identifier SEC itself uses, and `security.cik` is populated by `sec-cik-map`.
--
-- Inserts NOTHING on a database where the CIK has not landed yet, which is correct: migrations
-- re-run every deploy, so the row appears on the first deploy after the security exists.
insert into market.segment_alias (member_code, concept_code, security_id)
select v.member_code, v.concept_code, s.security_id
from (values
  ('us-gaap:ServiceMember',     'digital-services',    '0000320193'),  -- Apple Services
  ('us-gaap:AdvertisingMember', 'digital-advertising', '0001018724')   -- Amazon Advertising
) as v(member_code, concept_code, cik)
join market.security s on lpad(s.cik::text, 10, '0') = v.cik
on conflict do nothing;

-- ── And finally: something CALLS the derivation ───────────────────────────────────────────────
--
-- Wired into `derive-classifications` (the handler, migration 143 + index.ts) rather than into
-- `security-segments`: this is pure SQL over rows already written, it belongs with the other
-- taxonomy derivation, and running it on the segment resource's five-minute schedule would
-- recompute the whole table 288 times a day to no purpose — the "a time window is not a scope"
-- lesson, where a follow-on pass did 576,828 upserts to derive 28 rows.
comment on function market.derive_segment_classification() is
  'Turns disclosed segment revenue and operating income into weighted rows in security_taxonomy. Pure SQL — no provider, no rate limit, no backlog. Deletes weights whose segments no longer map, because an upsert cannot retract. INVOKED BY the `derive-classifications` resource, daily.';

notify pgrst, 'reload schema';
