-- Rank the curation queue by something that is not structurally constant — IDEMPOTENT.
--
-- MEASURED 2026-08-29 across every security holding a segment row: **380 distinct members, of
-- which 320 are filer-namespaced extensions, and ZERO of those are shared by two distinct
-- ISSUERS.** That is not a coverage artefact and it will not improve: an XBRL extension member is
-- minted in the filer's own namespace, so `amzn:AmazonWebServicesMember` and
-- `msft:IntelligentCloudMember` can never collide however many companies are parsed. The only
-- members two companies share are the STANDARD ones — and every one of those is geography
-- (`country:US` 18 issuers, `country:CN` 10, `country:JP` 8, `srt:EuropeMember` 6), which
-- migration 157 already resolves from `market.countries` with no curation at all.
--
-- THREE CONSEQUENCES, AND THE FIRST IS A BUG IN THIS VIEW.
--
-- 1. `order by companies desc` was the primary sort key and it is STRUCTURALLY 1 for every member
--    that matters. So the ranking collapsed to whatever came second, and the members that floated
--    to the top were exactly the ones that must NEVER be given a comparable concept: measured, the
--    live top of the queue was `us-gaap:ProductMember` (4), `us-gaap:AllOtherSegmentsMember` (3),
--    `ifrs-full:AllOtherSegmentsMember` (3), `us-gaap:CorporateAndOtherMember` (2) — catch-alls,
--    every one. A queue whose head is work you must not do is worse than an unordered one.
--
-- 2. `count(distinct security_id) as companies` COUNTS SECURITIES, NOT COMPANIES. TSMC's local
--    line (2330.TW) and its ADR (TSM) are two securities and one issuer, which is why four
--    `tsm:` members read as "2 companies" and looked like the only genuine cross-company overlap
--    in the queue. They are one company twice. Same family as the rule already recorded here: an
--    LEI identifies the ISSUER, not the security, and resolving on it merges distinct securities.
--
-- 3. The leverage measure has to be something that varies. FUND WEIGHT does: it is a percentage,
--    so it is free of currency (revenue is not — TSMC's TWD 3,272,600,000,000 outranks every US
--    line by exchange rate alone), and it says how much of what our users actually hold sits
--    behind the unmapped line.
--
-- THE CATCH-ALLS ARE FLAGGED, NOT FILTERED. A panel must not hide the state it exists to reveal,
-- and "how much of this company is in a bucket called Other" is a real answer about disclosure
-- quality. `is_catch_all` lets the operator sort past them; it does not drop them.

drop view if exists market.pending_segment_alias;
create view market.pending_segment_alias as
select
  c.member_code,
  min(c.kind)                        as kind,
  -- ISSUERS, not securities. A dual-listed company is one company.
  count(distinct s.issuer_id)        as issuers,
  count(distinct c.security_id)      as securities,
  -- The sort key, because `issuers` is 1 for every extension member by construction.
  max(coalesce(h.best_weight, 0))    as best_weight,
  max(c.revenue_share_pct)           as largest_share_pct,
  -- Context only, never the sort key: revenue is in the filer's own currency.
  max(c.revenue)                     as largest_revenue,
  max(c.currency_code)               as a_currency_code,
  min(c.axis)                        as an_axis,
  -- A residual bucket cannot BE a comparable concept: "All other segments" means something
  -- different in every filing, so mapping it would assert an equivalence that does not exist.
  -- Matched on the member's own name rather than a hand list, because the vocabulary is open.
  bool_or(c.member_code ~* '(AllOther|CorporateAndOther|OtherSegment|:Other[A-Z]|:OthersMember|Unallocated|Reconcil|Elimination|Intersegment)')
                                     as is_catch_all
from market.security_segment_spine c
join market.security s on s.security_id = c.security_id
left join lateral (
  select max(fh.weight) as best_weight
  from market.fund_holding_current fh
  where fh.security_id = c.security_id
) h on true
where c.concept_code is null
  -- Geography is not a curation task: `security_segment_geography` already serves the published
  -- members, and a product concept for a country would be a wrong answer rather than a missing one.
  and c.kind in ('product', 'business')
group by c.member_code
-- Catch-alls last, then by how much of the universe holds the company, then by how much of that
-- company the line is. `issuers` is deliberately NOT a sort key — see the header.
order by is_catch_all, best_weight desc nulls last, largest_share_pct desc nulls last, c.member_code;

comment on view market.pending_segment_alias is
  'Business lines with no shared concept. NOT ordered by how many companies use the member: an XBRL extension member is namespaced by its filer, so measured across the whole universe ZERO extension members are shared by two issuers and that number is structurally 1 rather than merely small. Ranked by fund weight (a percentage, so free of currency) with residual buckets last — they cannot be a comparable concept because "all other segments" means something different in every filing.';

grant select on market.pending_segment_alias to service_role;

notify pgrst, 'reload schema';
