-- `security_peers` JOINED A VIEW TO ITSELF. THE SPINE IS ALREADY MATERIALISED.
--
-- Migration 119 built the peer computation on `security_current` — twice, once for the subject and
-- once for each candidate — plus `security_market_cap_usd` twice more. `security_current` is a view
-- over LATERAL subqueries (one per security to resolve its sector), so a peer lookup evaluated
-- those laterals for every member of the sector. Measured against production as ANON: 0.89s for one
-- security's peers, and 3.49s unfiltered.
--
-- 0.89s is inside the 2,000ms budget and is not a bug today. It is the shape that has broken this
-- schema three times, though — `fund_sector_weight`, `security_facets` and `price_series` each
-- answered a probe in under a second and then timed out for anon once the universe grew or a second
-- filter arrived — and a sector's membership grows with every promoted listing.
--
-- `market.security_facets` (migration 80) is the MATERIALISED spine and already carries exactly
-- what this needs: `security_id`, `sector_id`, `market_cap_usd`, `symbol`, `name`. It exists
-- because the same per-row lateral cost had to be removed once before. Reading it makes the peer
-- lookup an indexed scan of a real table rather than a self-join over two view evaluations, and
-- bounds the cost as the universe grows instead of tuning it now and re-tuning it later.

drop view if exists market.security_peers;
create view market.security_peers as
select
  s.security_id,
  p.security_id      as peer_id,
  p.name             as peer_name,
  p.symbol           as peer_symbol,
  p.market_cap_usd   as peer_market_cap_usd,
  s.market_cap_usd   as market_cap_usd,
  s.sector_id,
  -- HOW CLOSE, in orders of magnitude rather than dollars. A $40bn difference means one thing
  -- between two $50bn companies and nothing at all between two $2tn ones, so the distance is a
  -- ratio: 0 is identical, 1 is a factor of ten apart.
  abs(ln(p.market_cap_usd / s.market_cap_usd) / ln(10)) as size_distance
from market.security_facets s
join market.security_facets p
  on p.sector_id = s.sector_id
 and p.security_id <> s.security_id
where s.sector_id is not null
  and s.market_cap_usd > 0
  and p.market_cap_usd > 0;

comment on view market.security_peers is
  'Companies in the same sector of a similar size, from the MATERIALISED spine rather than from `security_current` — that view resolves each security''s sector through a lateral, so a self-join over it paid that cost once per sector member. NOT a curated peer set: `equity/compare/peers` returns the same computation from a vendor whose free tier 402s per symbol. Distance is a log ratio because a $40bn gap means one thing between two $50bn companies and nothing between two $2tn ones.';

grant select on market.security_peers to anon, authenticated, service_role;

-- Serves the sector join on the spine. `security_facets` is a matview, so this is an index on real
-- rows rather than on a view's output.
create index if not exists security_facets_sector_cap_idx
  on market.security_facets (sector_id, market_cap_usd)
  where market_cap_usd > 0;

notify pgrst, 'reload schema';
