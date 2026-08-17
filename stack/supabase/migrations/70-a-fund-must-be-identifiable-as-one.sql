-- THE FIRST ETP SWEEP FILED 864 ETFs UNDER "MUTUAL FUND", AND THE ROWS WERE OTHERWISE PERFECT.
--
-- Migration 69 taught the sweep to enumerate funds by OpenFIGI's FINE type
-- (`securityType: 'ETP'`), because the coarse bucket is unusable — `securityType2: 'Mutual Fund'`
-- returns 44,119 US rows of open-end funds and blows the paging ceiling. That part worked: the
-- first Amsterdam slice wrote **1,013 listings**, and they are exactly what was wanted —
-- ISHARES FTSE ALL WORLD ETF, VANGUARD FTSE GLB AL-CAP ETF, ISHARES AT1 BD ACT UCITS ETF.
--
-- But `exchange_listing.security_type` stores `securityType2`, so every one of them landed labelled
-- **`Mutual Fund`**. Measured immediately after the sweep: `security_type = 'ETP'` returned **0**
-- rows while Amsterdam held 864 new ones. The sweep filtered on the fine type and recorded the
-- coarse type, so the directory could not distinguish an exchange-traded fund from an open-end
-- mutual fund — which is a different instrument that is not exchange-traded at all.
--
-- Found by checking the DATA rather than the response. The resource reported
-- `written: 1013, complete: true` and was telling the truth; every row was real; the defect was
-- one column holding the wrong one of two values the provider had already sent us.
--
-- WHY A NEW COLUMN RATHER THAN CHANGING WHAT `security_type` STORES. The two vocabularies disagree
-- in more places than ETFs, and the coarse one is what 102,390 existing rows already hold:
--
--   instrument      securityType (fine)    securityType2 (coarse)
--   common stock    Common Stock           Common Stock          <- agree
--   BABA's US line  ADR                    Depositary Receipt    <- DISAGREE
--   SPY             ETP                    Mutual Fund           <- DISAGREE
--
-- Overwriting the column would silently re-spell every receipt from `Depositary Receipt` to `ADR`
-- on its next sweep, changing the meaning of stored data as a side effect of a fund fix — and
-- `exchange_sweep_type.security_type` names the COARSE values, so the sweep's own control surface
-- would no longer match the rows it produces.

alter table market.exchange_listing
  add column if not exists figi_security_type text;

comment on column market.exchange_listing.figi_security_type is
  'OpenFIGI securityType (FINE). The only one that identifies a fund: an ETF is securityType ETP inside securityType2 Mutual Fund, so security_type alone cannot tell an exchange-traded fund from an open-end one. Null for rows catalogued before 2026-08-17; they carry it on their next sweep.';

-- Cheap and worth having: "show me the funds" is the whole point of the column, and the directory
-- is 103,455 rows.
create index if not exists exchange_listing_figi_security_type_idx
  on market.exchange_listing (figi_security_type)
  where figi_security_type is not null;

-- THE ROWS ALREADY WRITTEN CANNOT BE REPAIRED FROM WHAT WE HOLD, and that is stated rather than
-- papered over. `security_type = 'Mutual Fund'` on a venue we swept for ETPs is very probably an
-- ETP, but "very probably" is how wrong reference data gets created — the same reasoning that
-- keeps `security_taxonomy` carrying its source instead of picking a winner at write time. The
-- sweep re-enumerates every venue on a cycle and each row's `figi_security_type` is filled from
-- the provider when it is next seen. Until then the column is null, which is honest: it says "not
-- yet known", not "not a fund".
--
-- The one thing worth asserting now is that nothing READS the column as though null meant
-- something. `untracked_listing` and the search view select explicit columns and are unaffected.

notify pgrst, 'reload schema';
