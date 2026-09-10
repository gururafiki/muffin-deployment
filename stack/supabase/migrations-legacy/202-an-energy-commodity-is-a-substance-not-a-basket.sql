-- AN ENERGY COMMODITY IS A SUBSTANCE, NOT A BASKET AND NOT A PIPELINE.
--
-- Migration 200 established that commodities are the one cluster where a shared segment concept is
-- sound rather than editorial, and seeded the metals. The energy substances are the same rule
-- applied again, and they are cheaper per issuer than the metals were: these members come from
-- SHARED taxonomies (`srt:`, `us-gaap:`) rather than a filer's own namespace, so ONE generic alias
-- covers every issuer that files it — six rows here reach ~30 issuers, where 200 needed 67 rows to
-- reach ~60.
--
-- Measured 2026-09-07 against the live queue, issuers counted DISTINCT BY ISSUER (a dual-listed
-- company is one company):
--
--   srt:NaturalGasReservesMember          11      us-gaap:ElectricityMember      10
--   srt:NaturalGasLiquidsReservesMember   11      srt:CrudeOilMember              7
--   us-gaap:NaturalGasProductionMember     7      srt:OilReservesMember           6
--
-- Despite the name, the `...ReservesMember` members carry REVENUE and not reserve volumes — they
-- are the product dimension on a revenue disclosure. Checked rather than assumed: 15 rows, all
-- with a revenue figure, denominated in CNY and USD at magnitudes (avg ~39bn CNY) consistent with
-- the national producers that file them. A volume tagged as revenue would have been a units defect
-- of the kind this schema has hit four times.
--
-- ── WHAT IS DELIBERATELY EXCLUDED, AND WHY EACH ────────────────────────────────────────────────
--   us-gaap:OilAndGasMember          (6)  A BASKET. Oil and gas are two substances with different
--                                         prices; one concept holding both means a different
--                                         mixture per filer. Migration 200 excluded
--                                         `rio:CopperAndDiamondsMember` for exactly this.
--   us-gaap:OilAndCondensateMember   (5)  The same shape, one step subtler.
--   us-gaap:NaturalGasMidstreamMember(3)  Midstream is TRANSPORT. Moving gas is not selling gas.
--   us-gaap:OilAndGasServiceMember   (4)  Services, like the `bwxt` uranium member 200 rejected.
--   us-gaap:OilAndGasPurchasedMember (3)  A purchased volume — a cost line, not a product line.
--   us-gaap:NaturalGasUsRegulatedMember, us-gaap:ElectricityUsRegulatedMember
--                                    (4,3) A REGULATORY qualifier, not a substance. A regulated
--                                         utility's distribution business and a producer's
--                                         wellhead sales are the same molecule and not the same
--                                         business, and merging them would make the concept mean
--                                         whichever the reader happened to be looking at.
--
-- `oil-and-gas` already exists as a concept and is NOT reused for any of this: its single alias is
-- `xom:SalesAndOtherOperatingRevenueMember`, a revenue line rather than a commodity, so folding
-- crude oil into it would inherit that ambiguity rather than resolve it.

\set ON_ERROR_STOP on

insert into market.segment_concept (code, name, node_id)
select v.code, v.name, tn.node_id
from (values
  ('crude-oil',           'Crude oil',           'energy'),
  ('natural-gas',         'Natural gas',         'energy'),
  ('natural-gas-liquids', 'Natural gas liquids', 'energy'),
  -- Electricity is the product of the utilities sector rather than the energy sector; the existing
  -- `energy-storage` concept is pinned to `utilities` for the same reason.
  ('electricity',         'Electricity',         'utilities')
) as v(code, name, sector)
join market.taxonomy_node tn
  on tn.taxonomy_id = 'muffin' and tn.level = 1 and tn.code = v.sector
on conflict (code) do update set name = excluded.name, node_id = excluded.node_id;

-- GENERIC (null security_id) on purpose, and safe for the reason migration 200 set out: a standard
-- member naming a SUBSTANCE is unambiguous across filers, unlike one naming a ROLE
-- (`us-gaap:ProductMember`), which stays scoped per CIK.
-- `on conflict do nothing` with NO target — segment_alias uses two PARTIAL unique indexes.
insert into market.segment_alias (member_code, concept_code, security_id)
select v.member_code, v.concept_code, null::uuid
from (values
  ('srt:CrudeOilMember',                    'crude-oil'),
  ('srt:OilReservesMember',                 'crude-oil'),
  ('srt:NaturalGasReservesMember',          'natural-gas'),
  ('us-gaap:NaturalGasProductionMember',    'natural-gas'),
  ('srt:NaturalGasLiquidsReservesMember',   'natural-gas-liquids'),
  ('us-gaap:ElectricityMember',             'electricity')
) as v(member_code, concept_code)
on conflict do nothing;

notify pgrst, 'reload schema';
