-- Link the curated ADR picks to the securities they refer to — IDEMPOTENT.
--
-- `market.instruments` is a curated overlay (migration 40) and auto-links on any alias a security
-- answers to. That bridges most of it, but not the rows where somebody deliberately chose the LIQUID
-- ADR while the fund-derived universe knows the company by its local line: `TSM` is the NYSE ADR and
-- the security is `2330.TW`, so they share no symbol, no ticker and no provider symbol.
--
-- LINKED BY ISIN, NOT BY NAME. The name route has a trap this very set contains:
--
--   TW0002330008  Taiwan Semiconductor Manufacturing Company   <- what TSM is
--   TW0005425003  Taiwan Semiconductor Co Ltd                  <- a DIFFERENT, smaller company
--
-- A prefix or fuzzy name match picks whichever row the planner reaches first and would silently
-- point the world's largest foundry at an unrelated firm. An ISIN cannot do that.
--
-- Editorial rows, so they are written here rather than in Studio: a migration is reviewable, states
-- WHY each pair belongs together, and reproduces on a fresh database. `where security_id is null`
-- keeps a hand-made correction in Studio winning over this file.

update market.instruments i
   set security_id = s.security_id
  from market.security s
  join market.security_identifier isin
    on isin.security_id = s.security_id and isin.kind_code = 'isin'
 where i.security_id is null
   and (i.symbol, isin.value) in (
     ('TSM',  'TW0002330008'),   -- NYSE ADR       -> Taiwan Semiconductor Manufacturing (2330.TW)
     ('HSBC', 'GB0005405286'),   -- NYSE ADR       -> HSBC Holdings plc (HSBA.L)
     ('NVO',  'DK0062498333'),   -- NYSE ADR       -> Novo Nordisk A/S B shares (NOVO-B.CO)
     ('XOM',  'US30231G1022')    -- the US line    -> Exxon Mobil Corp.
   );

-- The remaining unlinked rows are NOT securities and must stay that way: USD (cash), US10Y (a
-- yield), BTC/ETH, WTI, GLD, and the fund wrappers SPY/QQQ/TLT/VNQ/VTSAX. `priced = false` on the
-- first two is what makes them render no number rather than "+0.0%".
