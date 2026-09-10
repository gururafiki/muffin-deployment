-- Type every security from the filing that reported it — IDEMPOTENT.
--
-- `ingest.ts` typed a security from N-PORT's `units` alone: `NS` (number of shares) became `equity`
-- and EVERYTHING ELSE became `other`. So 15,205 bonds, futures, repos and money-market positions
-- shared one type, and "E MINI RUSS 1000 VJUN26" sat beside "Saudi Government International Bonds"
-- as the same kind of thing.
--
-- The filings had the answer all along. `assetCat` is a REQUIRED N-PORT field with a closed
-- vocabulary, already captured on `fund_holding.asset_category_code` and already learned into
-- `market.asset_category`. Measured across the tracked funds: STIV, EC, DE, EP, RA, DFE, DBT,
-- ABS-MBS, ABS-O, LON. `market.security_type` already carried bond/cash/derivative/fund — only the
-- ingest was not using them.
--
-- `units` is the weaker signal and stays as the fallback: it is a unit of measure (NS = shares,
-- PA = principal amount), not a statement about the instrument.
--
-- ONLY WIDENS FROM `other`. A security already typed `equity`, `etf` or anything else keeps it —
-- the curated rows and the fund rows were set deliberately, and this must not overwrite them.

update market.security s
   set security_type_code = m.type_code
  from (
    select
      h.security_id,
      case max(h.asset_category_code)
        when 'EC'      then 'equity'
        when 'EP'      then 'equity'
        when 'DBT'     then 'bond'
        when 'ABS-MBS' then 'bond'
        when 'ABS-O'   then 'bond'
        when 'LON'     then 'bond'
        when 'DE'      then 'derivative'
        when 'DFE'     then 'derivative'
        when 'STIV'    then 'cash'
        when 'RA'      then 'cash'
      end as type_code
    from market.fund_holding h
    where h.asset_category_code is not null
    group by h.security_id
    -- A security reported under two different categories by different funds is left alone rather
    -- than resolved by a coin toss; `max()` with the count check keeps only the unambiguous ones.
    having count(distinct h.asset_category_code) = 1
  ) m
 where s.security_id = m.security_id
   and m.type_code is not null
   and s.security_type_code = 'other';
