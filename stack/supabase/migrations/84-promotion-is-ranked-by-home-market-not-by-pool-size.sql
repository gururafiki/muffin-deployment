-- PROMOTION IS RANKED BY HOME MARKET, NOT BY HOW MANY LISTINGS A VENUE HAS.
--
-- 92,826 of 108,105 exchange listings are untracked, across 59 venues. Every downstream backlog
-- (profiles, prices, statements, industries, fundamentals) is rate-limited by the SAME providers,
-- so promotion is not "add securities" — it is "decide what the next month of a fixed API budget
-- gets spent on". That makes the ORDER the whole feature.
--
-- ── THE OBVIOUS ORDER IS THE WRONG ONE (measured 2026-08-19) ─────────────────────────────────
--
-- Ranking venues by untracked count puts Frankfurt first: it has the largest pool at 15,711, ahead
-- of the US (10,160) and India (5,401 + 3,064). But a 400-listing sample per venue, matched by
-- name against securities already held:
--
--   venue   sampled   name already in universe   %
--   GR         400              73             18.3      <- Frankfurt
--   IB         400              24              6.0      India (BSE)
--   LN         400              21              5.3      London
--   HK         400              19              4.8      Hong Kong
--   US         400               2              0.5
--   JP         400               1              0.3
--
-- Nearly a fifth of Frankfurt's untracked listings are CROSS-LISTINGS of companies the universe
-- already holds under their home listing. `untracked_listing` cannot see this: it excludes by
-- composite FIGI, and `composite_figi` is per COUNTRY OF LISTING, not per company — the same fact
-- that made `exchange_listing.country_iso2` the venue's country rather than the issuer's. So the
-- listing genuinely is untracked while the COMPANY is not, and promoting it mints a duplicate
-- security that then consumes profile, price and statement calls of its own.
--
-- 18.3% is a LOWER BOUND: it counts exact name matches only, and a cross-listing often carries a
-- slightly different string ("AG" vs "AG NA", a transliteration).
--
-- Hence `promotion_tier` ranks HOME MARKETS first and cross-listing venues last. It is not a
-- quality judgement about Frankfurt — it is that a euro line of a US company is the one listing
-- whose data we already have.
--
-- ── DISABLED BY DEFAULT, AND THAT IS THE POINT ───────────────────────────────────────────────
--
-- `promotion_enabled` defaults to FALSE for every venue. Merging this changes nothing until an
-- operator opts a venue in. With 92,826 candidates against a fixed provider budget, a migration
-- that silently began promoting would starve every existing backlog — the backlogs that are
-- currently draining are the ones serving the securities people actually look at.

alter table market.exchange
  add column if not exists promotion_tier    integer not null default 9,
  add column if not exists promotion_enabled boolean not null default false;

comment on column market.exchange.promotion_tier is
  'Promotion order, lowest first. Ranks HOME MARKETS ahead of cross-listing venues: measured 2026-08-19, 18.3% of Frankfurt''s untracked listings name a company already held (against 0.5% for the US), because composite_figi is per country of listing and cannot see that the company is already tracked.';
comment on column market.exchange.promotion_enabled is
  'Opt-in per venue. FALSE by default on purpose — 92,826 listings are untracked and every downstream backlog shares one rate-limited provider budget, so promotion must be a decision someone takes, not something a deploy starts.';

-- Tier 1: deep home markets where an untracked listing is almost always a company we do not hold
-- (US 0.5% duplicate, JP 0.3%).
update market.exchange set promotion_tier = 1 where exch_code in ('US','JP','JT','LN','HK','KS','CN','AU','SW');
-- Tier 2: substantial home markets, still mostly domestic issuers.
update market.exchange set promotion_tier = 2 where exch_code in ('IB','IS','TB','KQ','TT','SS','SZ','BZ','MM','SM','NA','ST','CO','HE','ID','PL','NO');
-- Tier 3: everything else that is a home market for someone.
update market.exchange set promotion_tier = 3 where promotion_tier = 9 and exch_code not in ('GR','GF','GY','GB','GM','GS','GT','GD','GQ','EO','EB','QT','TQ','XETR');
-- Tier 8: the German regional venues and pan-European MTFs, which are overwhelmingly cross-listings.
update market.exchange set promotion_tier = 8
 where exch_code in ('GR','GF','GY','GB','GM','GS','GT','GD','GQ','EO','EB','QT','TQ','XETR');

-- ── the backlog ──────────────────────────────────────────────────────────────────────────────
drop view if exists market.pending_promotion;

create view market.pending_promotion as
select
  l.figi,
  l.composite_figi,
  l.exch_code,
  l.ticker,
  l.name,
  l.country_iso2,
  l.provider_symbol,
  e.promotion_tier,
  e.preference
from market.untracked_listing l
join market.exchange e on e.exch_code = l.exch_code
-- OPT-IN ONLY. An anti-join over a disabled venue would be a slow way of returning nothing; this
-- is the filter that makes "disabled by default" mean something.
where e.promotion_enabled
  and e.enabled
  -- NAME-DEDUPED against what we already hold. This is the 18.3% the FIGI test cannot catch, and
  -- it belongs in the BACKLOG rather than in the promoting code: a resource that fetched a listing
  -- and then discarded it has already spent the call.
  and not exists (
    select 1 from market.security s where upper(s.name) = upper(l.name)
  )
order by e.promotion_tier, e.preference, l.name;

comment on view market.pending_promotion is
  'Listings eligible for promotion, in the order a fixed provider budget should spend itself: home markets first, cross-listing venues last, opted in per venue and name-deduped against securities already held. Empty until an operator sets promotion_enabled — see the column comment.';

grant select on market.pending_promotion to anon, authenticated, service_role;

-- Supports the anti-join above; without it the name dedupe is a sequential scan of `security`
-- for every candidate listing.
create index if not exists security_upper_name_idx on market.security (upper(name));

notify pgrst, 'reload schema';
