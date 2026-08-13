-- Broaden the universe beyond country and sector funds — IDEMPOTENT.
--
-- The tracked funds were 19 country ETFs, the classification-group ETFs and the 11 sector SPDRs, so
-- the universe is whatever those hold: large-cap equities, and nothing else. These eleven add style,
-- size, thematic and fixed-income exposure — the instrument kinds a wealth app is expected to cover.
--
-- EVERY ONE WAS CHECKED AGAINST SEC'S `company_tickers_mf.json` BEFORE BEING ADDED, because the
-- alternative is what happened with EGPT/NGE/PGAL: a fund that cannot be ingested, failing on every
-- run, with a country page priced off a dead ticker. Four candidates were REJECTED by that check,
-- and the reason is structural rather than bad luck:
--
--   SLV  iShares Silver Trust      a commodity TRUST, not a 1940-Act fund
--   USO  United States Oil Fund    a commodity POOL (files 10-K)
--   DBC  Invesco DB Commodity      a commodity pool
--   MDY  SPDR S&P MidCap 400       a UNIT INVESTMENT TRUST — UITs file no N-PORT
--
-- So commodity exposure and the UIT-structured index funds cannot come from this route at all. That
-- is the same class of limit as non-US UCITS funds, and belongs in `todos.md` rather than in a
-- retry loop.
--
-- `kind = 'other'`: these represent neither a country nor a sector, so nothing should try to derive
-- classification membership from them. `represents_code` stays null for the same reason — it is
-- what `derive-classifications` joins on, and a style fund is not evidence that its holdings ARE
-- that style.

insert into market.tracked_fund (symbol, name, kind) values
  -- Style and size: the holdings are ordinary large/mid/small caps, so these mostly DEEPEN coverage
  -- of names the sector funds already touch rather than adding new ones. IWM is the exception —
  -- 2,000 small caps the S&P-based funds do not hold at all.
  ('IWF',  'iShares Russell 1000 Growth',            'other'),
  ('IWD',  'iShares Russell 1000 Value',             'other'),
  ('IWM',  'iShares Russell 2000',                   'other'),
  ('RSP',  'Invesco S&P 500 Equal Weight',           'other'),
  -- Thematic: concentrated, and the reason "AI infrastructure / cyber security" is on the roadmap.
  ('SMH',  'VanEck Semiconductor',                   'other'),
  ('ICLN', 'iShares Global Clean Energy',            'other'),
  -- Fixed income: these hold BONDS, which the model already types as `security_type_code` other
  -- than equity. They will not appear in sector pages (correctly) and are the first instruments
  -- here that are not shares.
  ('AGG',  'iShares Core US Aggregate Bond',         'other'),
  ('LQD',  'iShares iBoxx Investment Grade Corp',    'other'),
  ('HYG',  'iShares iBoxx High Yield Corp',          'other'),
  ('TIP',  'iShares TIPS Bond',                      'other'),
  ('EMB',  'iShares JP Morgan USD EM Bond',          'other')
on conflict (symbol) do nothing;
