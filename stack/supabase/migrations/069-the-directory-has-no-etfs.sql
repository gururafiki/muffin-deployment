-- THE EXCHANGE DIRECTORY CONTAINS NO ETFs AT ALL, AND NOTHING COULD HAVE REPORTED IT.
--
-- Measured 2026-08-17 against production: of 102,390 rows in `market.exchange_listing`,
-- **99,673 are Common Stock and 2,717 are Depositary Receipts. Zero are funds.** Meanwhile the
-- tracked universe holds **74** ETFs — every one of them hand-added to `market.tracked_fund` for
-- its N-PORT holdings, none of them discovered.
--
-- That is not a bug in the sweep, it is the sweep's stated filter: `exchange_sweep_type` has held
-- exactly two rows since migration 53, and `listExchange` sends whichever one the cursor is on.
-- A directory that omits an entire asset class is invisible to every count in the system —
-- coverage percentages are all computed over `security_type_code = 'equity'`, the backlogs all
-- drain, `market-verify` is green, and search simply never offers an ETF. THE FAILURE IS AN
-- ABSENCE, and absences do not raise. Same shape as `exchange-listings` being off the cron
-- (nothing invokes it, so it cannot fail) and `untracked_listing` going unread for weeks.
--
-- WHY THIS NEEDS A NEW COLUMN RATHER THAN JUST A THIRD ROW. OpenFIGI has TWO type vocabularies
-- and they are not interchangeable. Measured directly against `/v3/filter` with our key:
--
--   securityType2 = 'Mutual Fund'   exchCode US  ->  44,119   FEUCX, WATFX, NPRTX, CMNWX …
--   securityType  = 'ETP'           exchCode US  ->   6,664   DGP, UWM, SAA, MNA, EWH, ICLN, MDY
--
-- SPY resolves as `securityType: 'ETP'` INSIDE `securityType2: 'Mutual Fund'`. So the coarse
-- bucket is both wrong and unusable: 44,119 is over OpenFIGI's 15,000 paging ceiling, and its
-- contents are overwhelmingly open-end mutual funds, which are not exchange-traded and have no
-- business in an exchange directory. The fine field gives exactly the exchange-traded products,
-- clean and comfortably inside the ceiling.
--
-- `figi_field` records which of the two a sweep type filters on, next to the type itself, so
-- adding a fund class stays a row in Studio rather than a deploy — the same reason
-- `exchange_sweep_type` exists at all.
--
-- SCOPE, deliberately: this catalogues ETFs so they are searchable and promotable. It does NOT
-- make them tracked funds. Ingesting holdings for 6,664 ETFs would mean 6,664 N-PORT filings
-- against SEC's ~10 req/s fair-access limit and would swamp every downstream backlog; and most of
-- them are not US-registered and file no N-PORT at all. `tracked_fund` stays the deliberate,
-- curated control surface it is. This makes choosing the next one a query instead of a memory.

alter table market.exchange_sweep_type
  add column if not exists figi_field text not null default 'securityType2';

do $$ begin
  alter table market.exchange_sweep_type
    add constraint exchange_sweep_type_figi_field_ck
    check (figi_field in ('securityType', 'securityType2'));
exception when duplicate_object then null; end $$;

comment on column market.exchange_sweep_type.figi_field is
  'Which OpenFIGI field this type filters on. securityType2 is the coarse bucket (Common Stock, Depositary Receipt); securityType is the fine one, and ETP is only reachable through it — its coarse bucket is Mutual Fund, 44,119 US rows of mostly open-end funds, over the 15,000 paging ceiling.';

-- Existing rows are securityType2 values and the default already says so; state it anyway so the
-- table reads correctly rather than relying on a default that a later migration might change.
update market.exchange_sweep_type
   set figi_field = 'securityType2'
 where security_type in ('Common Stock', 'Depositary Receipt');

insert into market.exchange_sweep_type (security_type, sort_order, figi_field, notes) values
  ('ETP', 3, 'securityType',
   'Exchange-traded products — ETFs, ETNs, commodity trusts. Measured 2026-08-17: 6,664 on the US venue alone against the 74 ETFs the universe held, all of them hand-added. Filtered on securityType, NOT securityType2: SPY is securityType ETP inside securityType2 Mutual Fund, and that bucket returns 44,119 US rows of mostly open-end mutual funds, which are not exchange-traded and are over the paging ceiling.')
on conflict (security_type) do update
  set sort_order = excluded.sort_order,
      figi_field = excluded.figi_field,
      notes      = excluded.notes;

notify pgrst, 'reload schema';
