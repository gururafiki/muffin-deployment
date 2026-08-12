-- `market.instruments` is a CURATED OVERLAY, not a second universe — IDEMPOTENT.
--
-- It was going to be retired into `security`. Measuring it first showed that would have destroyed
-- information. Of its 47 rows, only 27 exist in the fund-derived universe under the same name, and
-- the other 20 split into two groups that are both deliberate:
--
--   EDITORIAL LISTING PICKS (8): TSM, SAP, NVO, HSBC, RIO, BHP, SHEL, NESN — the liquid ADR or home
--     line, where the fund-derived universe knows the company only as a thin OTC foreign-ordinary
--     (`TSMWF`, `SAPGF`, `NSRGF`). Somebody chose the tradeable one. That is a judgement, not a
--     duplicate.
--   NOT SECURITIES AT ALL (12): USD (cash), US10Y (a yield), BTC/ETH, WTI, GLD, TLT, VNQ, VTSAX,
--     SPY, QQQ. Folding these into `security` would mean asserting that a currency and a bond yield
--     are securities with issuers and identifiers, to satisfy a table shape.
--
-- So this keeps the table and states what it is. `asset_type`, `priced` and `sort_order` are real
-- editorial data the fund-derived model has no concept of — `priced = false` is what makes cash and
-- a 10-year yield render NO number rather than "+0.0%".
--
-- The parallel-universe problem was never the table; it was that nothing connected the two. That is
-- what `security_id` fixes.

alter table market.instruments add column if not exists security_id uuid references market.security (security_id);
create index if not exists instruments_security_idx on market.instruments (security_id);

comment on column market.instruments.security_id is
  'The fund-derived security this curated instrument refers to, where one exists. NULL for cash, yields, crypto and commodities, which are not securities. Auto-linked by any name the security is known by; the ADR picks (TSM -> Taiwan Semiconductor) must be set by hand in Studio, and survive a redeploy because this table is seeded `on conflict do nothing`.';

-- ── auto-link on ANY name the security answers to ───────────────────────────
-- Not on `security_symbol`: that is one preferred name per security, and after migration 39 it is
-- the local line — so `NESN` would match nothing even though the security is right there. Matching
-- across every known alias (ticker identifier, provider symbol, and both listing columns) links what
-- can be linked without guessing.
update market.instruments i
   set security_id = m.security_id
  from (
    select distinct on (alias) alias, security_id from (
      select t.value           as alias, t.security_id  from market.security_identifier t where t.kind_code = 'ticker'
      union all
      select ps.symbol         as alias, ps.security_id from market.security_provider_symbol ps
      union all
      select l.provider_symbol as alias, l.security_id  from market.listing l where l.provider_symbol is not null
      union all
      select l.symbol          as alias, l.security_id  from market.listing l where l.symbol is not null
    ) x
    where alias is not null
    order by alias, security_id
  ) m
 where i.security_id is null
   and (m.alias = i.symbol or m.alias = i.price_symbol);

-- ── one thing for the app to read ───────────────────────────────────────────
-- The curated row WINS on the fields it exists to carry (asset_type, priced, sort_order, and its
-- chosen symbol). The security supplies what is refreshed from providers (market cap, currency,
-- sector, industry) — so a curated instrument stops going stale the moment it is linked, without
-- the editorial choices being overwritten by whatever a provider happened to say.
drop view if exists market.instrument_current;
create view market.instrument_current as
select
  i.symbol,
  coalesce(i.name, s.name)                as name,
  i.asset_type,
  i.priced,
  i.sort_order,
  i.price_symbol,
  i.security_id,
  coalesce(s.sector_id, i.sector_id)      as sector_id,
  coalesce(s.industry, i.industry)        as industry,
  coalesce(s.country_name, i.country)     as country,
  coalesce(s.market_cap, i.market_cap)    as market_cap,
  coalesce(s.currency_code, i.currency)   as currency,
  i.provider_sector,
  i.updated_at
from market.instruments i
left join market.security_current s on s.security_id = i.security_id;

comment on view market.instrument_current is
  'The curated instrument list, enriched from the linked security where there is one. Curated columns win for editorial fields (asset_type, priced, sort_order, symbol); provider-refreshed fields (market cap, currency, sector, industry) come from the security so a linked instrument does not go stale.';

grant select on market.instrument_current to anon, authenticated, service_role;

notify pgrst, 'reload schema';
