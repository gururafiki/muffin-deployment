-- The countries an index group names but the app could not open — IDEMPOTENT.
--
-- Measured 2026-08-10: MSCI Emerging has 24 members and only 12 were modelled with an ETF, so a
-- group page listed 14 countries under "Also in this group" with no drill-down. That was never a
-- decision — the original scope was 19 countries — and single-country ETFs exist for most of them.
--
-- `market.countries` already holds all 221 countries; only `etf_symbol` was missing, which is what
-- `country-performance` reads. Setting it makes the country's growth real, and the matching
-- `tracked_fund` row makes its holdings ingestible.
--
-- Deliberately NOT here: Kuwait and Qatar. iShares' KWT and QAT were both liquidated, so there is
-- no free price series to point at — adding a symbol that returns nothing would render an empty
-- card that looks broken rather than honestly absent.

update market.countries c set etf_symbol = v.etf from (values
  ('PL','EPOL'),  -- iShares MSCI Poland
  ('ID','EIDO'),  -- iShares MSCI Indonesia
  ('TH','THD'),   -- iShares MSCI Thailand
  ('TR','TUR'),   -- iShares MSCI Turkey
  ('MY','EWM'),   -- iShares MSCI Malaysia
  ('PH','EPHE'),  -- iShares MSCI Philippines
  ('PE','EPU'),   -- iShares MSCI Peru
  ('GR','GREK'),  -- Global X MSCI Greece
  ('CO','GXG'),   -- Global X MSCI Colombia
  ('EG','EGPT'),  -- VanEck Egypt Index
  ('CZ','EEM'),   -- no single-country fund; EEM is a PROXY and is marked as such below
  ('HU','EEM'),   -- same
  ('IT','EWI'),   -- iShares MSCI Italy
  ('ES','EWP'),   -- iShares MSCI Spain
  ('NL','EWN'),   -- iShares MSCI Netherlands
  ('SE','EWD'),   -- iShares MSCI Sweden
  ('SG','EWS'),   -- iShares MSCI Singapore
  ('NZ','ENZL'),  -- iShares MSCI New Zealand
  ('IL','EIS'),   -- iShares MSCI Israel
  ('NO','NORW'),  -- Global X MSCI Norway
  ('DK','EDEN'),  -- iShares MSCI Denmark
  ('BE','EWK'),   -- iShares MSCI Belgium
  ('AT','EWO'),   -- iShares MSCI Austria
  ('IE','EIRL'),  -- iShares MSCI Ireland
  ('FI','EFNL'),  -- iShares MSCI Finland
  ('PT','PGAL'),  -- Global X MSCI Portugal
  ('VN','VNM'),   -- VanEck Vietnam
  ('AR','ARGT'),  -- Global X MSCI Argentina
  ('NG','NGE')    -- Global X MSCI Nigeria
) as v(iso2, etf)
-- `is null` only: never overwrite a symbol someone corrected in Studio. Same rule as every other
-- piece of editable reference data here.
where c.iso2 = v.iso2 and c.etf_symbol is null;

-- CZ and HU point at EEM, which is the whole emerging-markets basket rather than the country. That
-- would be a number wearing the wrong name, so they are cleared again — better no figure than a
-- misattributed one. Kept in the list above so the next person can see they were considered.
update market.countries set etf_symbol = null where iso2 in ('CZ','HU') and etf_symbol = 'EEM';

-- Make the new country funds ingestible too, so their holdings feed the universe.
insert into market.tracked_fund (symbol, name, kind, represents_code)
select c.etf_symbol, c.name, 'country', c.iso2
from market.countries c
where c.etf_symbol is not null
on conflict (symbol) do nothing;

-- Backfill represents_code for any country fund seeded before that column existed.
update market.tracked_fund tf set represents_code = c.iso2
from market.countries c
where c.etf_symbol = tf.symbol and tf.kind = 'country' and tf.represents_code is null;

notify pgrst, 'reload schema';
