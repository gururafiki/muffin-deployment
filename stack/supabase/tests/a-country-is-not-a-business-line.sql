-- A MEMBER'S KIND IS NOT ITS AXIS'S KIND.
--
-- WHY. `security_segment_current.kind` was read straight off `segment_axis`, which is right for
-- the axis and wrong for the member: a company whose REPORTABLE SEGMENTS ARE GEOGRAPHIC files
-- countries on `us-gaap:StatementBusinessSegmentsAxis`, because that is what it reports. Measured
-- in production 2026-08-29 on the business axis — `country:TW` 299.4bn, `srt:NorthAmericaMember`
-- 178.2bn, `srt:AsiaPacificMember` 53.8bn, `srt:SouthAmericaMember` 11.6bn.
--
-- Two things break if the axis decides. The curation queue asks a human to give Taiwan a PRODUCT
-- concept, which is a wrong answer rather than a missing one — 41 of 113 queued members were this.
-- And `derive_segment_classification` chooses the axis with the most MAPPED members among
-- `kind in ('product','business')`, so the moment somebody reasonably maps a region member, WHERE
-- a company earns would be written into `security_taxonomy` as WHAT it does.
--
-- THE FIXTURE MAKES THE TWO RULES DISAGREE. Every geographic member here sits on the BUSINESS
-- axis, so under the axis rule all three are `business` and none is geography; under the member
-- rule the reverse. A fixture that filed them on the geography axis would pass under either rule
-- and prove nothing. It also carries one genuine business member on the same axis, so the rule
-- cannot be "everything on this axis is geography" either.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('ZT','Testonia','ZT',false) on conflict (iso2) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;

-- `market.segment_member` derives its country rows FROM `market.countries`, so a country inserted
-- by this fixture has no member row until the seed is re-run. Insert it the way the migration
-- would, or the test asserts against a table that never met this country.
insert into market.segment_member (member_code, kind, country_iso2, label)
  values ('country:ZT','geography','ZT','Testonia')
on conflict (member_code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000015701', 'T157 Geographic Segments', 'equity', 'ZT')
on conflict (security_id) do nothing;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code) values
  -- All four on the BUSINESS axis, which is what the company actually files.
  ('00000000-0000-0000-0000-000000015701','us-gaap:StatementBusinessSegmentsAxis','country:ZT','revenue','annual',date '2025-12-31',40,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000015701','us-gaap:StatementBusinessSegmentsAxis','srt:NorthAmericaMember','revenue','annual',date '2025-12-31',30,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000015701','us-gaap:StatementBusinessSegmentsAxis','us-gaap:NonUsMember','revenue','annual',date '2025-12-31',20,'USD',1,'sec-segments'),
  -- …and one that really is a business line, so "this axis is geography" cannot pass either.
  ('00000000-0000-0000-0000-000000015701','us-gaap:StatementBusinessSegmentsAxis','zt:FoundryMember','revenue','annual',date '2025-12-31',10,'USD',1,'sec-segments'),
  -- A PUBLISHED member that is NOT a geography. Without it every row carrying a `member_label` is
  -- geographic, so `where kind = 'geography'` and `where member_label is not null` agree and the
  -- filter can be deleted with the test still passing — measured, that mutation escaped once.
  ('00000000-0000-0000-0000-000000015701','srt:ProductOrServiceAxis','us-gaap:AutomobilesMember','revenue','annual',date '2025-12-31',100,'USD',1,'sec-segments')
on conflict do nothing;

-- A MATERIALIZED VIEW MAKES EVERY FIXTURE-BASED TEST A SNAPSHOT TEST. `pending_segment_alias` and
-- `security_segment_geography` read `security_segment_spine` (migration 158), so rows inserted in
-- this transaction are invisible to them until it is rebuilt — the assertions below failed for a
-- reason that had nothing to do with their subject. NON-concurrently, deliberately:
-- `refresh ... concurrently` cannot run inside a transaction block, and a test that cannot roll
-- back is not a test.
refresh materialized view market.security_segment_spine;

do $$
declare
  geo int; biz int; queued int; named int; iso text;
begin
  select count(*) into geo from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000015701' and kind = 'geography';
  if geo <> 3 then
    raise exception '% of 3 geographic members read as geography — a country filed on the business axis is still a country', geo;
  end if;

  select count(*) into biz from market.security_segment_current
   where security_id = '00000000-0000-0000-0000-000000015701' and kind = 'business';
  if biz <> 1 then
    raise exception '% members read as business rather than 1 — the member must override the axis, not replace it', biz;
  end if;

  -- The curation queue must ask about the business line and NOT about the countries.
  select count(*) into queued from market.pending_segment_alias q
   where q.member_code in ('country:ZT','srt:NorthAmericaMember','us-gaap:NonUsMember');
  if queued <> 0 then
    raise exception '% geographic members are queued for a product concept — that is a wrong answer waiting to be curated, not a missing one', queued;
  end if;
  select count(*) into queued from market.pending_segment_alias q
   where q.member_code = 'zt:FoundryMember';
  if queued <> 1 then
    raise exception 'the genuine business line is not in the curation queue (% rows) — excluding geography must not exclude everything', queued;
  end if;

  -- And the geography view must NAME them, which is the whole payoff: no curation was involved.
  select count(*) into named from market.security_segment_geography
   where security_id = '00000000-0000-0000-0000-000000015701';
  if named <> 3 then
    raise exception 'security_segment_geography returns % rows rather than 3 — either a published member needs an alias to be readable, or a published PRODUCT member (us-gaap:AutomobilesMember) is being served as a place the company earns', named;
  end if;

  select country_iso2 into iso from market.security_segment_geography
   where security_id = '00000000-0000-0000-0000-000000015701' and member_code = 'country:ZT';
  if iso is distinct from 'ZT' then
    raise exception 'country:ZT resolves to % rather than ZT — the ISO member must join the country table it was derived from', coalesce(iso,'null');
  end if;

  -- THE COUNTRY MEMBERS ARE DERIVED FROM `market.countries`, NOT TYPED OUT. Authoring reference
  -- data from memory is what once silently dropped Taiwan from the world map, and a seed listing
  -- "the countries that matter" would leave the rest of the world reading as an unmapped business
  -- line for ever. Asserted as COVERAGE because that is the only form the claim takes that a
  -- fixture can see: a mutation replacing the `select ... from market.countries` with a literal
  -- list passes every per-row check above and fails this one.
  select count(*) into named from market.countries;
  select count(*) into queued from market.segment_member where country_iso2 is not null;
  if queued <> named then
    raise exception 'market.countries has % rows and segment_member has % country members — the ISO members must be derived from the country table, not authored', named, queued;
  end if;

  -- A REGION IS NOT A COUNTRY. `us-gaap:NonUsMember` is "everywhere except the US"; pinning it to
  -- one ISO code would put a whole company's foreign revenue in a single arbitrary country.
  select country_iso2 into iso from market.security_segment_geography
   where security_id = '00000000-0000-0000-0000-000000015701' and member_code = 'us-gaap:NonUsMember';
  if iso is not null then
    raise exception 'us-gaap:NonUsMember resolves to country % — a region names an area, not a country', iso;
  end if;
end $$;

rollback;

\echo 'ok: a country filed on the business axis is geography, is named without curation, and is not queued for one'
