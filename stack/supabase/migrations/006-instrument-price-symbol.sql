-- Separate an instrument's DISPLAY ticker from the symbol the price provider knows.
--
-- Found on the first production refresh (2026-08-09): `instrument-performance`
-- reported `unmapped: ["NESN"]` and `instrument-profile` returned 34 of 35 rows.
-- Nestlé's authored ticker is `NESN`, but on yfinance the SIX listing is `NESN.SW`
-- — the bare ticker resolves to nothing. Every other name in the seed happens to
-- have a US listing or ADR (BHP, RIO, SHEL, HSBC, NVO, SAP, TSM), which is why only
-- one row failed.
--
-- Rather than rename the primary key (the UI shows `symbol` as the ticker, and
-- "NESN.SW" is not what a user wants to read), the provider symbol is its own
-- nullable column. The refresh uses `coalesce(price_symbol, symbol)`, so this stays
-- empty for the common case and exists only where the two genuinely differ.

alter table market.instruments
  add column if not exists price_symbol text;

comment on column market.instruments.price_symbol is
  'Symbol the price provider knows, when it differs from the display ticker '
  '(e.g. NESN -> NESN.SW on yfinance). NULL means they are the same.';

update market.instruments
   set price_symbol = 'NESN.SW'
 where symbol = 'NESN' and price_symbol is null;

notify pgrst, 'reload schema';
