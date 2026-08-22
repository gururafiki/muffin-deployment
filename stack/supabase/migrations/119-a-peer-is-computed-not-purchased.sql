-- PEERS, FROM DATA THIS SCHEMA ALREADY HOLDS.
--
-- The plan called for `equity/compare/peers` (FMP). Reading what that endpoint actually returns
-- settles it: peers there are SECTOR PLUS MARKET-CAP PROXIMITY — SAP.DE comes back beside Micron
-- and SK hynix — which is a computation, not a curated list. This schema has the sector
-- (`security_current.sector_id`) and the cap in a comparable currency
-- (`security_market_cap_usd`, migration 73), so the computation can be done here.
--
-- Doing it here is strictly better, and not merely cheaper:
--
--   * FMP's free tier is per-SYMBOL, not per-endpoint. Measured previously on
--     `equity/fundamental/metrics`: AAPL/MSFT/NVDA answer while NEE, PLD, BHP and SAP return 402,
--     including every non-US name tried. A peer list that 402s for most of the universe is a
--     feature that cannot serve the page it was built for — the exact shape that got the
--     fundamentals feature reverted.
--   * It costs no calls at all, on any budget, for any security.
--   * And it is HONEST about what it is. "Companies of a similar size in the same sector" is what
--     the number means; "peers" from a vendor implies an editorial judgement nobody made.
--
-- ── THE CAP MUST BE IN ONE CURRENCY, AND THAT IS THE WHOLE TRAP ─────────────────────────────────
--
-- `security.market_cap` is denominated in each security's OWN currency, so ranking on it directly
-- would put a ¥3,000,000,000,000 company beside a $3,000,000,000 one and call them comparable —
-- wrong by two orders of magnitude and entirely plausible-looking. Migration 73 exists for this;
-- this view uses its output rather than the raw column.

drop view if exists market.security_peers;
create view market.security_peers as
select
  s.security_id,
  p.security_id                 as peer_id,
  p.name                        as peer_name,
  p.symbol                      as peer_symbol,
  pc.market_cap_usd             as peer_market_cap_usd,
  sc.market_cap_usd             as market_cap_usd,
  s.sector_id,
  -- HOW CLOSE, in orders of magnitude rather than dollars. A $40bn difference means one thing
  -- between two $50bn companies and nothing at all between two $2tn ones, so the distance is a
  -- ratio: 0 is identical, 1 is a factor of ten apart.
  abs(ln(pc.market_cap_usd / sc.market_cap_usd) / ln(10)) as size_distance
from market.security_current s
join market.security_market_cap_usd sc on sc.security_id = s.security_id
join market.security_current p on p.sector_id = s.sector_id and p.security_id <> s.security_id
join market.security_market_cap_usd pc on pc.security_id = p.security_id
where s.sector_id is not null
  and sc.market_cap_usd > 0
  and pc.market_cap_usd > 0;

comment on view market.security_peers is
  'Companies in the same sector of a similar size, computed from `security_current.sector_id` and `security_market_cap_usd`. NOT a curated peer set and deliberately not named as one — `equity/compare/peers` returns the same computation from a vendor whose free tier 402s per symbol. Distance is a log ratio because a $40bn gap means one thing between two $50bn companies and nothing between two $2tn ones.';

grant select on market.security_peers to anon, authenticated, service_role;

-- Serves the join: for one security, its sector's members by cap.
create index if not exists security_sector_cap_idx
  on market.security (security_type_code, market_cap)
  where market_cap is not null;

notify pgrst, 'reload schema';
