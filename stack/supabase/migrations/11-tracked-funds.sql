-- Seed the funds whose SEC N-PORT holdings build the securities universe.
--
-- `on conflict do nothing` ON PURPOSE: this file is a STARTING POINT, not the source of truth.
-- `market.tracked_fund` is the control surface — adding an ETF is meant to be an insert in
-- Supabase Studio, never a migration and a deploy. A redeploy must not revert an addition, a
-- rename, or an `enabled = false`.
--
-- Scope: the 19 single-country ETFs already referenced by market.countries.etf_symbol, the
-- classification-group ETFs from market.classification_groups.etf, and the 11 sector SPDRs.
-- Everything else (style, size, thematic, bond, commodity) is deliberately out of scope for now —
-- see todos.md. Adding one is a row, not a code change.
--
-- Only US-registered funds file N-PORT, so a non-US UCITS fund cannot be tracked here at all.

insert into market.tracked_fund (symbol, name, kind) values
  -- Single-country (iShares MSCI unless noted) — mirrors market.countries.etf_symbol
  ('IVV',  'iShares Core S&P 500',            'country'),
  ('EWC',  'iShares MSCI Canada',             'country'),
  ('EWW',  'iShares MSCI Mexico',             'country'),
  ('EWU',  'iShares MSCI United Kingdom',     'country'),
  ('EWG',  'iShares MSCI Germany',            'country'),
  ('EWQ',  'iShares MSCI France',             'country'),
  ('EWL',  'iShares MSCI Switzerland',        'country'),
  ('EWJ',  'iShares MSCI Japan',              'country'),
  ('EWA',  'iShares MSCI Australia',          'country'),
  ('INDA', 'iShares MSCI India',              'country'),
  ('EWY',  'iShares MSCI South Korea',        'country'),
  ('MCHI', 'iShares MSCI China',              'country'),
  ('EWH',  'iShares MSCI Hong Kong',          'country'),
  ('EWT',  'iShares MSCI Taiwan',             'country'),
  ('EWZ',  'iShares MSCI Brazil',             'country'),
  ('ECH',  'iShares MSCI Chile',              'country'),
  ('KSA',  'iShares MSCI Saudi Arabia',       'country'),
  ('EZA',  'iShares MSCI South Africa',       'country'),
  ('UAE',  'iShares MSCI UAE',                'country'),
  -- Classification-group proxies — mirrors market.classification_groups.etf
  ('IEUR', 'iShares Core MSCI Europe',        'group'),
  ('EPP',  'iShares MSCI Pacific ex-Japan',   'group'),
  ('EEMA', 'iShares MSCI Emerging Asia',      'group'),
  ('EEM',  'iShares MSCI Emerging Markets',   'group'),
  ('ILF',  'iShares Latin America 40',        'group'),
  ('FM',   'iShares Frontier & Select EM',    'group'),
  ('VEA',  'Vanguard Developed Markets',      'group'),
  ('VWO',  'Vanguard Emerging Markets',       'group'),
  ('URTH', 'iShares MSCI World',              'group'),
  -- Sector SPDRs — one per muffin sector, which is what makes the donut derivable
  ('XLK',  'Technology Select Sector SPDR',   'sector'),
  ('XLF',  'Financial Select Sector SPDR',    'sector'),
  ('XLV',  'Health Care Select Sector SPDR',  'sector'),
  ('XLY',  'Consumer Discretionary SPDR',     'sector'),
  ('XLP',  'Consumer Staples Select SPDR',    'sector'),
  ('XLC',  'Communication Services SPDR',     'sector'),
  ('XLI',  'Industrial Select Sector SPDR',   'sector'),
  ('XLE',  'Energy Select Sector SPDR',       'sector'),
  ('XLB',  'Materials Select Sector SPDR',    'sector'),
  ('XLU',  'Utilities Select Sector SPDR',    'sector'),
  ('XLRE', 'Real Estate Select Sector SPDR',  'sector')
on conflict (symbol) do nothing;

notify pgrst, 'reload schema';
