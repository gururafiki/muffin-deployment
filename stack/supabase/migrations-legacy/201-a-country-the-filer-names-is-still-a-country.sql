-- A COUNTRY THE FILER NAMES IN ITS OWN NAMESPACE IS STILL A COUNTRY.
--
-- Migration 157 established that "a country is a country on whatever axis it arrives" and resolved
-- the PUBLISHED geography members — `country:XX`, `srt:NorthAmericaMember`, `us-gaap:NonUsMember`
-- — so they are served as geography and never queued for a product concept, which would be "a
-- wrong answer waiting to be curated, not a missing one".
--
-- It cannot see a country a filer names in its OWN namespace. Measured 2026-09-07 against the live
-- curation queue: 43 of its 9,020 business-line rows are an exact country name wearing a filer
-- prefix, and they are heavy — MercadoLibre's Argentina/Brazil/Mexico at 20.3% fund weight,
-- Apple's Japan at 13.6, Costco's United States and Canada at 9.6. They were being offered for a
-- PRODUCT concept.
--
-- `market.segment_member` is a control table and this is a data change, not a view change: a
-- member listed here overrides its axis's kind, so these leave `pending_segment_alias` and appear
-- in `security_segment_geography` with no curation at all — which is the same payoff 157 bought
-- for the standard members.
--
-- Costco and Apple are the cases worth stating plainly. Costco's reportable segments ARE
-- geographic, so after this it has fewer business lines rather than more — that is the correct
-- answer, not a regression. Apple keeps its product members (iPhone, Mac, Wearables are already
-- mapped) and gains a properly-typed Japan.
--
-- ── WHY 43 LITERAL ROWS AND NOT A NAME-MATCHING RULE ───────────────────────────────────────────
-- Deriving this from `market.countries` at migration time is the obvious shape and is UNSAFE, for
-- reasons that are not hypothetical: `Georgia` is a US state far more often than it is a country
-- in an American filing, `Jordan` is a Nike brand, `Chad` and `Turkey` are a name and a bird. None
-- of the three appears in the 43 below — every one was READ from the live queue and eyeballed
-- against its issuer (VAALCO really does operate in Gabon, Egypt and Equatorial Guinea; Butterfield
-- really is a Bermuda bank) — but a standing rule would adopt them the moment a poultry producer
-- or a US regional bank files one. The rows were generated FROM the database rather than
-- transcribed, so no member code here was authored by hand.
--
-- The exact-full-name match is also why this is only 43 rows and not the several hundred a looser
-- "contains a place word" test suggests: `scco:PeruvianOperationsMember` and `bud:EMEAMember` are
-- geographies too, and neither is a country name — an adjective and a region need a different
-- mechanism, and inventing one here would be guessing.

\set ON_ERROR_STOP on

insert into market.segment_member (member_code, kind, country_iso2, label) values
  ('meli:ArgentinaSegmentMember', 'geography', 'AR', 'Argentina'),
  ('gme:AustraliaSegmentMember', 'geography', 'AU', 'Australia'),
  ('titn:AustraliaMember', 'geography', 'AU', 'Australia'),
  ('wds:AustraliaSegmentMember', 'geography', 'AU', 'Australia'),
  ('ntb:BermudaSegmentMember', 'geography', 'BM', 'Bermuda'),
  ('amx:BrazilSegmentMember', 'geography', 'BR', 'Brazil'),
  ('arco:BrazilSegmentMember', 'geography', 'BR', 'Brazil'),
  ('meli:BrazilSegmentMember', 'geography', 'BR', 'Brazil'),
  ('mt:BrazilSegmentMember', 'geography', 'BR', 'Brazil'),
  ('acu:CanadaSegmentMember', 'geography', 'CA', 'Canada'),
  ('cost:CanadaMember', 'geography', 'CA', 'Canada'),
  ('egy:CanadaMember', 'geography', 'CA', 'Canada'),
  ('ferg:CanadaSegmentMember', 'geography', 'CA', 'Canada'),
  ('gme:CanadaSegmentMember', 'geography', 'CA', 'Canada'),
  ('hlmn:CanadaSegmentMember', 'geography', 'CA', 'Canada'),
  ('mur:CanadaSegmentMember', 'geography', 'CA', 'Canada'),
  ('vsts:CanadaSegmentMember', 'geography', 'CA', 'Canada'),
  ('qdel:ChinaSegmentMember', 'geography', 'CN', 'China'),
  ('amx:ColombiaSegmentMember', 'geography', 'CO', 'Colombia'),
  ('lila:CostaRicaSegmentMember', 'geography', 'CR', 'Costa Rica'),
  ('egy:EgyptMember', 'geography', 'EG', 'Egypt'),
  ('egy:GabonSegmentMember', 'geography', 'GA', 'Gabon'),
  ('gpi:UnitedKingdomSegmentMember', 'geography', 'GB', 'United Kingdom'),
  ('kos:GhanaSegmentMember', 'geography', 'GH', 'Ghana'),
  ('egy:EquatorialGuineaSegmentMember', 'geography', 'GQ', 'Equatorial Guinea'),
  ('kos:EquatorialGuineaSegmentMember', 'geography', 'GQ', 'Equatorial Guinea'),
  ('nse:IndiaMember', 'geography', 'IN', 'India'),
  ('aapl:JapanSegmentMember', 'geography', 'JP', 'Japan'),
  ('ew:JapanSegmentMember', 'geography', 'JP', 'Japan'),
  ('amx:MexicoSegmentMember', 'geography', 'MX', 'Mexico'),
  ('laur:MexicoSegmentMember', 'geography', 'MX', 'Mexico'),
  ('meli:MexicoSegmentMember', 'geography', 'MX', 'Mexico'),
  ('upbd:MexicoMember', 'geography', 'MX', 'Mexico'),
  ('laur:PeruSegmentMember', 'geography', 'PE', 'Peru'),
  ('acu:UnitedStatesSegmentMember', 'geography', 'US', 'United States'),
  ('cost:UnitedStatesMember', 'geography', 'US', 'United States'),
  ('ew:UnitedStatesSegmentMember', 'geography', 'US', 'United States'),
  ('ferg:UnitedStatesSegmentMember', 'geography', 'US', 'United States'),
  ('flut:UnitedStatesSegmentMember', 'geography', 'US', 'United States'),
  ('gme:UnitedStatesSegmentMember', 'geography', 'US', 'United States'),
  ('gpi:UnitedStatesSegmentMember', 'geography', 'US', 'United States'),
  ('mur:UnitedStatesSegmentMember', 'geography', 'US', 'United States'),
  ('prlb:UnitedStatesSegmentMember', 'geography', 'US', 'United States')
on conflict (member_code) do update
  set kind = excluded.kind, country_iso2 = excluded.country_iso2, label = excluded.label;

notify pgrst, 'reload schema';
