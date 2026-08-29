-- A SORT KEY THAT IS STRUCTURALLY CONSTANT IS NOT A RANKING.
--
-- WHY. `pending_segment_alias` shipped `order by companies desc`, where `companies` counted the
-- distinct securities using an XBRL member. Measured across every security holding a segment row:
-- 380 distinct members, **320 filer-namespaced extensions, ZERO shared by two distinct ISSUERS**.
-- An extension member is minted in the filer's own namespace, so `amzn:AmazonWebServicesMember`
-- and `msft:IntelligentCloudMember` can never collide however much of the universe is parsed —
-- the key is 1 for every member that matters, not merely usually 1.
--
-- The ranking therefore collapsed to whatever came second, and what floated to the head of the
-- queue was exactly the work that must NEVER be done: `us-gaap:ProductMember`,
-- `AllOtherSegmentsMember`, `CorporateAndOtherMember` — residual buckets that mean something
-- different in every filing. A queue whose top row is a wrong answer is worse than no queue.
--
-- It also counted SECURITIES as companies: TSMC's local line and its ADR are two securities and
-- one issuer, which made four `tsm:` members read as the only cross-company overlap in the queue.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. The heavily-held company's line must outrank a
-- catch-all that a dual-listed company uses twice — so ranking by `count(distinct security_id)`
-- puts the catch-all first, ranking by issuers ties them, and only fund weight with catch-alls
-- demoted gives the right head.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZR','Rankland','ZR',false)
  on conflict (iso2) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;

-- ONE issuer, TWO securities — the dual-listing shape that made `companies` lie.
insert into market.issuer (issuer_id, name) values
  ('00000000-0000-0000-0000-0000000162a1', 'T162 Dual Issuer'),
  ('00000000-0000-0000-0000-0000000162b1', 'T162 Held Issuer')
on conflict (issuer_id) do nothing;

insert into market.security (security_id, issuer_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000016201','00000000-0000-0000-0000-0000000162a1','T162 Dual Local','equity','ZR'),
  ('00000000-0000-0000-0000-000000016202','00000000-0000-0000-0000-0000000162a1','T162 Dual ADR',  'equity','ZR'),
  ('00000000-0000-0000-0000-000000016203','00000000-0000-0000-0000-0000000162b1','T162 Held Co',   'equity','ZR')
on conflict (security_id) do nothing;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code) values
  -- The dual-listed issuer uses a CATCH-ALL, twice — once per security. Under the old rule this
  -- scored 2 "companies" and led the queue.
  ('00000000-0000-0000-0000-000000016201','srt:ProductOrServiceAxis','zr:AllOtherSegmentsMember','revenue','annual',date '2025-12-31',90,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000016201','srt:ProductOrServiceAxis','zr:DualRealLineMember',    'revenue','annual',date '2025-12-31',10,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000016202','srt:ProductOrServiceAxis','zr:AllOtherSegmentsMember','revenue','annual',date '2025-12-31',90,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000016202','srt:ProductOrServiceAxis','zr:DualRealLineMember',    'revenue','annual',date '2025-12-31',10,'USD',1,'sec-segments'),
  -- The heavily-held issuer has ONE security and a genuine business line worth mapping.
  ('00000000-0000-0000-0000-000000016203','srt:ProductOrServiceAxis','zr:CloudPlatformMember',   'revenue','annual',date '2025-12-31',70,'USD',1,'sec-segments'),
  ('00000000-0000-0000-0000-000000016203','srt:ProductOrServiceAxis','zr:LegacyMember',          'revenue','annual',date '2025-12-31',30,'USD',1,'sec-segments')
on conflict do nothing;

refresh materialized view market.security_segment_spine;

do $$
declare head text; head_catch boolean; iss int; secs int;
begin
  -- 1. The head of the queue must not be a residual bucket.
  select member_code, is_catch_all into head, head_catch
  from market.pending_segment_alias
   where member_code in ('zr:AllOtherSegmentsMember','zr:DualRealLineMember',
                         'zr:CloudPlatformMember','zr:LegacyMember')
   limit 1;
  if head_catch then
    raise exception 'the queue leads with %, a residual bucket — "all other segments" means something different in every filing, so it can never be a comparable concept and heading the queue with it is worse than no ordering', head;
  end if;

  -- 2. A dual-listed company is ONE company.
  select issuers, securities into iss, secs from market.pending_segment_alias
   where member_code = 'zr:DualRealLineMember';
  if iss <> 1 then
    raise exception 'zr:DualRealLineMember reports % issuers rather than 1 — a local line and its ADR are two securities and one company, and counting securities made four tsm: members look like the only cross-company overlap in the queue', iss;
  end if;
  if secs <> 2 then
    raise exception 'zr:DualRealLineMember reports % securities rather than 2 — both counts are kept on purpose, so the difference is visible rather than hidden', secs;
  end if;

  -- 3. And the catch-all must still be PRESENT — flagged, not filtered. A panel must not hide the
  --    state it exists to reveal, and "90% of this company is in a bucket called Other" is a real
  --    answer about disclosure quality.
  if not exists (select 1 from market.pending_segment_alias
                  where member_code = 'zr:AllOtherSegmentsMember' and is_catch_all) then
    raise exception 'the residual bucket is missing from the queue or is not flagged — it must be demoted, never dropped';
  end if;
end $$;

rollback;

\echo 'ok: the queue ranks by something that varies, counts issuers, and demotes rather than hides'
