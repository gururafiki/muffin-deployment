-- Instruments: the tickers shown under each sector.
-- GENERATED from muffin-ui's REPRESENTATIVE_TICKERS by scratchpad/gen-instruments-sql.ts.
--
-- WHAT IS AUTHORED VS FETCHED:
--   * `sector_id` is a CURATED placement — which muffin sector bucket a ticker appears
--     under. Editing the universe (adding/removing tickers, re-bucketing) is a Studio
--     edit, hence `do nothing` on conflict: a redeploy must not revert it.
--   * `name`, `industry`, `country`, `market_cap`, `currency` and `provider_sector`
--     are FETCHED by the market-refresh edge function from equity/profile.
--
-- `provider_sector` is stored alongside the curated `sector_id` deliberately: yfinance
-- says "Financial Services" where muffin says "financials", so keeping both makes a
-- genuine disagreement visible instead of silently overwriting an editorial choice.

create table if not exists market.instruments (
  symbol          text primary key,
  name            text,
  -- Curated bucket (authored). Not necessarily equal to provider_sector.
  sector_id       text references market.sectors (id) on delete set null,
  -- Fetched from the provider.
  provider_sector text,
  industry        text,
  country         text,
  market_cap      numeric,
  currency        text,
  asset_type      text not null default 'equity',
  sort_order      integer not null default 0,
  updated_at      timestamptz
);

create index if not exists instruments_sector_idx on market.instruments (sector_id, sort_order);

insert into market.instruments (symbol, name, sector_id, sort_order) values
  ('AAPL', 'Apple', 'information-technology', 1),
  ('MSFT', 'Microsoft', 'information-technology', 2),
  ('NVDA', 'NVIDIA', 'information-technology', 3),
  ('TSM', 'TSMC', 'information-technology', 4),
  ('SAP', 'SAP', 'information-technology', 5),
  ('JPM', 'JPMorgan Chase', 'financials', 1),
  ('BAC', 'Bank of America', 'financials', 2),
  ('HSBC', 'HSBC', 'financials', 3),
  ('V', 'Visa', 'financials', 4),
  ('JNJ', 'Johnson & Johnson', 'health-care', 1),
  ('PFE', 'Pfizer', 'health-care', 2),
  ('NVO', 'Novo Nordisk', 'health-care', 3),
  ('UNH', 'UnitedHealth', 'health-care', 4),
  ('AMZN', 'Amazon', 'consumer-discretionary', 1),
  ('TSLA', 'Tesla', 'consumer-discretionary', 2),
  ('NKE', 'Nike', 'consumer-discretionary', 3),
  ('PG', 'Procter & Gamble', 'consumer-staples', 1),
  ('KO', 'Coca-Cola', 'consumer-staples', 2),
  ('NESN', 'Nestlé', 'consumer-staples', 3),
  ('GOOGL', 'Alphabet', 'communication-services', 1),
  ('META', 'Meta Platforms', 'communication-services', 2),
  ('NFLX', 'Netflix', 'communication-services', 3),
  ('CAT', 'Caterpillar', 'industrials', 1),
  ('BA', 'Boeing', 'industrials', 2),
  ('GE', 'GE Aerospace', 'industrials', 3),
  ('XOM', 'ExxonMobil', 'energy', 1),
  ('CVX', 'Chevron', 'energy', 2),
  ('SHEL', 'Shell', 'energy', 3),
  ('LIN', 'Linde', 'materials', 1),
  ('BHP', 'BHP Group', 'materials', 2),
  ('RIO', 'Rio Tinto', 'materials', 3),
  ('NEE', 'NextEra Energy', 'utilities', 1),
  ('DUK', 'Duke Energy', 'utilities', 2),
  ('PLD', 'Prologis', 'real-estate', 1),
  ('AMT', 'American Tower', 'real-estate', 2)
on conflict (symbol) do nothing;

grant select on market.instruments to anon, authenticated;
grant select, insert, update, delete on market.instruments to service_role;

notify pgrst, 'reload schema';
