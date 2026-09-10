-- The multi-asset universe: ETFs, commodities, crypto, bonds, funds, cash.
--
-- Closes the last place muffin-ui rendered invented numbers WITHOUT a sample badge
-- (the Markets drill list, ~50 authored `changePct` values — muffin-ui ROADMAP M6).
--
-- These ride in `market.instruments` alongside the equities rather than a second
-- table: they differ only by `asset_type`, and one universe means one refresh.
--
-- NOT EVERYTHING HAS A PRICE RETURN. Cash is 0% by definition and a bond YIELD is a
-- level, not a return — showing "+4.1%" for US10Y would mean the yield moved, which
-- reads as a gain and is not one. `priced = false` marks those: the refresh skips
-- them, so they render with NO number rather than a misleading one. That is the same
-- rule the UI already follows for a missing row.

alter table market.instruments
  add column if not exists priced boolean not null default true;

comment on column market.instruments.priced is
  'False when a price return is meaningless (cash, a bond yield). The refresh skips '
  'these and the UI shows no number rather than an invented or misleading one.';

create index if not exists instruments_asset_type_idx on market.instruments (asset_type, sort_order);

-- `sector_id` is null for non-equities: they are not in a GICS sector, and the
-- sector page must not pick them up.
insert into market.instruments
  (symbol, name, sector_id, asset_type, price_symbol, priced, country, sort_order) values
  ('SPY',   'S&P 500 ETF',             null, 'etf',         null,      true,  'United States', 101),
  ('QQQ',   'Nasdaq 100 ETF',          null, 'etf',         null,      true,  'United States', 102),
  ('EEM',   'Emerging Markets ETF',    null, 'etf',         null,      true,  null,            103),
  ('GLD',   'Gold',                    null, 'commodity',   null,      true,  null,            104),
  -- WTI spot has no ticker; the front-month future is the standard proxy.
  ('WTI',   'Crude Oil (WTI)',         null, 'commodity',   'CL=F',    true,  null,            105),
  ('BTC',   'Bitcoin',                 null, 'crypto',      'BTC-USD', true,  null,            106),
  ('ETH',   'Ethereum',                null, 'crypto',      'ETH-USD', true,  null,            107),
  ('TLT',   '20+ Year Treasury ETF',   null, 'bond',        null,      true,  'United States', 108),
  -- A yield level, not a tradeable return — see `priced` above.
  ('US10Y', 'US 10Y Treasury',         null, 'bond',        '^TNX',    false, 'United States', 109),
  ('VNQ',   'US REIT ETF',             null, 'real-estate', null,      true,  'United States', 110),
  ('VTSAX', 'Total Stock Market Fund', null, 'mutual-fund', null,      true,  'United States', 111),
  ('USD',   'US Dollar (cash)',        null, 'cash',        null,      false, 'United States', 112)
on conflict (symbol) do nothing;

notify pgrst, 'reload schema';
