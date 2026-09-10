-- A COMMODITY IS THE SAME SUBSTANCE WHOEVER MINES IT, WHICH ALMOST NOTHING ELSE IN THIS SCHEMA IS.
--
-- Segment collection finished and produced something that cannot be compared. Measured 2026-09-07:
-- 357,732 segment rows over 2,418 securities from four regulators, and `segments.comparable_concepts`
-- — concepts held by two or more issuers — sampled at **7**, the largest being `digital-advertising`
-- at four issuers. 11,123 of 11,170 served members (99.6%) carry no concept at all.
--
-- That is structural rather than neglect. Migration 162 measured 380 members of which 320 were
-- filer-namespaced and ZERO were shared by two issuers, so members never collide by construction and
-- comparability can only ever come from mapping. The queue is 9,621 deep against 50 hand-authored
-- aliases, and hand-mapping ~9,000 filer-specific business lines is not a plan.
--
-- Commodities are the one cluster where the mapping is sound rather than editorial. "Copper" means
-- the same substance in Freeport's filing and Vedanta's; "Solutions" and "Services" do not.
--
-- ── THE RULE: KEYWORD GENERATES, SECTOR FILTERS, REVIEW ADOPTS ─────────────────────────────────
-- A keyword rule cannot be the mapping. Every member below was read out of
-- `market.security_segment_spine` — the parser's own output in production — on 2026-09-07, and then
-- crossed against the issuer's own sector, which rejected these:
--
--   mbuu:CobaltMember              Malibu Boats — COBALT IS A BOAT BRAND, not the metal
--   hood:GoldSubscriptionRevenues  Robinhood Gold, a subscription tier
--   nse:GoldLoanAndOtherMember     gold-backed LENDING
--   samg:SilvercrestFundsMember    Silvercrest, an asset manager
--   cp:CoalRevenueMember           Canadian Pacific — a railroad HAULING coal
--   csx:CoalServicesMember         CSX — likewise
--   cp:PotashRevenueMember         the same railroad, hauling potash
--   cnx:CoalbedMethaneMember       coalbed methane is NATURAL GAS
--   aem:GoldexMineSubsegmentMember "Goldex" is a mine name
--   form:DRAMProductGroupMember    FormFactor sells test probes FOR DRAM, not DRAM
--   bwxt:UraniumAndNuclearServices BWX sells nuclear SERVICES
--
-- Every one of those sits outside `materials`/`information-technology`; every accepted member sits
-- inside it. This is `security-symbol-repair`'s rule — generate candidates and verify each before
-- adopting it, never pattern-match and rewrite — and it is why the raw keyword tally (17 "gold"
-- issuers) is an overcount that must not be reported as a result.
--
-- ── TWO FURTHER EXCLUSIONS, BOTH DELIBERATE ───────────────────────────────────────────────────
-- A MULTI-COMMODITY MEMBER IS NOT THE COMMODITY. `rio:CopperAndDiamondsMember`,
-- `nse:ZincLeadAndSilverMember` and `nse:ZincLeadAndOthersMember` are baskets; mapping them would
-- make `copper` and `zinc` mean a different mixture for each issuer, which is precisely the defect
-- this file exists to remove. Rio and Vedanta still contribute through their single-commodity
-- members, so the concept loses nothing. `rio:AluminiumAluminaAndBauxiteMember` is excluded for a
-- second reason: Rio also tags `rio:AluminiumMember`, and both would be the same metal twice.
--
-- ONE ISSUER IS NOT A COMPARISON. `nickel` (Sibanye alone) and the platinum-group members (Sibanye
-- alone, across three differently-scoped segments) are left unmapped rather than seeded at one
-- issuer, where they would grow `segment_concept` without moving the number this is measured by.
--
-- ── WHY MOST OF THESE ARE GENERIC RATHER THAN SECURITY-SCOPED ─────────────────────────────────
-- Migration 141: a null `security_id` means "any filer using this code", and is "only safe for
-- company-extension members that carry the filer's own prefix". `abx:`, `fcx:`, `teck:` and DART's
-- `entity00164779:` (SK hynix's corp code) all satisfy that directly.
--
-- Two kinds of shared member are seeded generically anyway, and the distinction is the point:
-- A STANDARD MEMBER NAMING A SUBSTANCE IS UNAMBIGUOUS; ONE NAMING A ROLE IS NOT. `us-gaap:GoldMember`
-- is used by SSR Mining, Royal Gold, Freeport and Coeur and means the metal in all four —
-- unlike `us-gaap:ProductMember` and `us-gaap:ServiceMember`, which migration 145 correctly scoped
-- per CIK because they mean Apple Services in one filing and Cisco support contracts in another.
-- The same holds for India: `nse:` is NOT filer-namespaced — it is NSE's shared taxonomy, so
-- `nse:CopperMember` is filed by both Hindalco and Vedanta and `nse:IronOreMember` by both Vedanta
-- and NMDC. That shared vocabulary is cross-company comparability for free, and it is the only
-- place in this schema where it arrives without curation.
--
-- The risk of a generic mapping being abused by some future filer is covered by the plausibility
-- tripwire (a mapped member whose issuer sector disagrees with the concept's is reported), not by
-- refusing the mapping.
--
-- Expected effect, stated so it can be checked rather than assumed: `segments.comparable_concepts`
-- 7 -> ~20, and the largest concept from 4 issuers to ~13 (copper). The metric reads
-- `security_segment_spine`, so it moves on the next `refresh_facets`, not on deploy.

-- ── AND THE OBVIOUS GUARD FOR ALL THIS DOES NOT WORK, WHICH WAS MEASURED BEFORE SHIPPING ONE ──
-- The plan for this change carried a plausibility tripwire: flag any alias whose concept sector
-- disagrees with the issuer's own sector, since that is exactly what rejected the eleven false
-- positives above. Run against production before writing it, it returns TWELVE groups and every
-- one is innocent — Amazon's cloud and physical retail, Alphabet's cloud, Microsoft's gaming and
-- advertising, Meta's wearables, Tesla's energy storage. A diversified company reporting a segment
-- outside its own sector is not an anomaly, it is the entire reason segment data exists.
--
-- So sector agreement is a CURATION FILTER — useful once, against the modal sector of a keyword
-- cluster, with a human reading the survivors — and NOT an invariant. Shipping it as a standing
-- check would have produced a guard that is ~100% false positives on correct data, which this
-- codebase has already learnt gets disabled and then hides the true positive behind it. It is
-- deliberately not shipped. The finding that a coal concept pinned to `energy` disagreed with four
-- of its own five issuers came out of the same measurement, and that one WAS a defect — in the
-- seed above, not in a guard.

\set ON_ERROR_STOP on

-- ── The vocabulary ────────────────────────────────────────────────────────────────────────────
-- Pinned to the level-1 sector by CODE, never by the uuid, which is generated.
insert into market.segment_concept (code, name, node_id)
select v.code, v.name, tn.node_id
from (values
  ('gold',        'Gold',        'materials'),
  ('copper',      'Copper',      'materials'),
  ('silver',      'Silver',      'materials'),
  ('zinc',        'Zinc',        'materials'),
  ('aluminium',   'Aluminium',   'materials'),
  ('iron-ore',    'Iron ore',    'materials'),
  ('molybdenum',  'Molybdenum',  'materials'),
  ('lithium',     'Lithium',     'materials'),
  ('potash',      'Potash',      'materials'),
  -- Uranium sits under `energy`, where Energy Fuels and Centrus both classify. COAL DOES NOT, and
  -- that was settled by measuring rather than by GICS: of the five issuers reporting a coal
  -- segment, FOUR (BHP, Vale, Sasol, Alpha Metallurgical) classify `materials` and only Peabody
  -- is `energy`. Metallurgical coal for steel and thermal coal for power are genuinely different
  -- products, but almost no filer splits them — `amr` is the sole exception — so one concept
  -- pinned where its holders actually sit beats two concepts that cannot be populated.
  ('coal',        'Coal',        'materials'),
  ('uranium',     'Uranium',     'energy'),
  ('dram',        'DRAM',        'information-technology'),
  ('nand',        'NAND flash',  'information-technology')
) as v(code, name, sector)
join market.taxonomy_node tn
  on tn.taxonomy_id = 'muffin' and tn.level = 1 and tn.code = v.sector
on conflict (code) do update set name = excluded.name, node_id = excluded.node_id;

-- ── The aliases ───────────────────────────────────────────────────────────────────────────────
-- `on conflict do nothing` with NO target: migration 141 uses two PARTIAL unique indexes rather
-- than a primary key, and a partial index is not covered by `on conflict (a,b)`.
insert into market.segment_alias (member_code, concept_code, security_id)
select v.member_code, v.concept_code, null::uuid
from (values
  -- gold
  ('us-gaap:GoldMember',                  'gold'),   -- SSR Mining, Royal Gold, Freeport, Coeur
  ('abx:GoldConcentrateMember',           'gold'),
  ('gfi:GoldProductsMember',              'gold'),
  ('hmy:GoldMember',                      'gold'),
  ('nem:GoldDoreMember',                  'gold'),   -- doré is unrefined gold
  ('rio:Gold1Member',                     'gold'),
  ('sbsw:GoldMiningActivitiesMember',     'gold'),
  ('teck:GoldMember',                     'gold'),
  -- copper
  ('abx:CopperMember',                    'copper'),
  ('abx:CopperconcentrateMember',         'copper'),
  ('bhp:CopperMember',                    'copper'),
  ('fcx:CopperCathodeMember',             'copper'),
  ('fcx:CopperInConcentratesMember',      'copper'),
  ('gfi:CopperMember',                    'copper'),
  ('hl:CopperMember',                     'copper'),
  ('nse:CopperMember',                    'copper'),  -- Hindalco AND Vedanta: NSE's shared taxonomy
  ('paas:CopperConcentrateMember',        'copper'),
  ('rgld:CopperMember',                   'copper'),
  ('rio:CopperRioTintoKennecottMember',   'copper'),
  ('scco:CopperMember',                   'copper'),
  ('teck:CopperMember',                   'copper'),
  ('teck:CopperSegmentMember',            'copper'),
  -- silver
  ('abx:SilverRevenueMember',             'silver'),
  ('gfi:SilverMember',                    'silver'),
  ('hmy:SilverMember',                    'silver'),
  ('nse:SilverMetalMember',               'silver'),
  ('paas:SilverConcentrateMember',        'silver'),
  ('rgld:SilverMember',                   'silver'),
  ('scco:SilverMember',                   'silver'),
  ('ssrm:SilverMember',                   'silver'),
  ('teck:SilverMember',                   'silver'),
  -- zinc
  ('nse:ZincInternationalMember',         'zinc'),
  ('paas:ZincConcentrateMember',          'zinc'),
  ('sbsw:ZincMiningActivitiesMember',     'zinc'),
  ('scco:ZincMember',                     'zinc'),
  ('ssrm:ZincMember',                     'zinc'),
  ('teck:ZincMember',                     'zinc'),
  ('teck:ZincSegmentMember',              'zinc'),
  -- aluminium
  ('nse:AluminiumMember',                 'aluminium'),  -- Vedanta AND National Aluminium
  ('nse:AluminiumUpstreamMember',         'aluminium'),
  ('nse:AluminiumDownstreamMember',       'aluminium'),
  ('rio:AluminiumMember',                 'aluminium'),
  -- iron ore
  ('bhp:IronOreMember',                   'iron-ore'),
  ('nse:IronOreMember',                   'iron-ore'),   -- Vedanta AND NMDC
  ('rio:IronOreMember',                   'iron-ore'),
  -- coal
  ('amr:CoalMetMember',                   'coal'),
  ('amr:CoalThermalMember',               'coal'),
  ('bhp:CoalMember',                      'coal'),
  ('btu:ThermalCoalMember',               'coal'),
  ('ssl:CoalMember',                      'coal'),
  ('vale:CoalMember',                     'coal'),
  -- molybdenum
  ('fcx:MolybdenumMember',                'molybdenum'),
  ('scco:MolybdenumMember',               'molybdenum'),
  ('teck:MolybdenumMember',               'molybdenum'),
  -- lithium
  ('rio:LithiumMember',                   'lithium'),
  ('sqm:LithiumAndDerivativesMember',     'lithium'),
  -- uranium
  ('efr:UraniumSegmentMember',            'uranium'),
  ('hmy:UraniumMember',                   'uranium'),
  ('leu:UraniumMember',                   'uranium'),
  -- potash
  ('ipi:PotashMember',                    'potash'),
  ('mos:PotashSegmentMember',             'potash'),
  -- memory. DART namespaces by corp code, so `entity00164779:` is SK hynix and nobody else. The
  -- same product arrives on two axes (a revenue-by-item table and a products-and-services table),
  -- which is the shape migration 145 already seeded for Amazon Web Services.
  ('entity00164779:DramMemberOfSegmentsMemberOfDisclosureOfAnalysisOfRevenueFromContractsWithCustomersByItemTableOfMember', 'dram'),
  ('entity00164779:DramMemberOfProductsAndServicesMemberOfDisclosureOfRevenueFromContractsWithCustomersByProductAndServiceTypesAbstractTableOfMember', 'dram'),
  ('mu:DRAMProductsMember',               'dram'),
  ('entity00164779:NandFlashMemberOfSegmentsMemberOfDisclosureOfAnalysisOfRevenueFromContractsWithCustomersByItemTableOfMember', 'nand'),
  ('entity00164779:NandFlashMemberOfProductsAndServicesMemberOfDisclosureOfRevenueFromContractsWithCustomersByProductAndServiceTypesAbstractTableOfMember', 'nand'),
  ('mu:NANDProductsMember',               'nand')
) as v(member_code, concept_code)
on conflict do nothing;

notify pgrst, 'reload schema';
