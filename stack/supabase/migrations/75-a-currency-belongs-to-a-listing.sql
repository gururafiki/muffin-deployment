-- A CURRENCY IS A PROPERTY OF A LISTING, NOT OF A SECURITY, AND FLATTENING THEM IS WHAT LET A
-- PROVIDER'S WRONG ANSWER OVERWRITE A RIGHT ONE.
--
-- Camtek trades as `CAMT` on Nasdaq in USD and as `CAMT.TA` on Tel Aviv in shekels. Those are two
-- true facts about two different listings. `security.currency_code` holds ONE value, so the
-- question "which currency is this security in?" has no correct answer — and whichever fetch ran
-- last won.
--
-- That is the root cause of the Jakarta defect, not the provider's bad data. yfinance returning
-- `currency: USD` for `BREN.JK` is upstream nonsense, but it could only corrupt us because the
-- claim had nowhere to live except a single column shared by every listing of that security. The
-- narrow repair in migration 74 detects the extreme cases; this removes the place they come from.
--
-- ── WHAT THIS DOES AND DELIBERATELY DOES NOT DO ───────────────────────────────────────────────
--
-- DOES: `listing.currency_code` becomes the normalized fact — the currency of THAT listing on THAT
-- venue. The fundamentals fetch is keyed by a provider symbol, that symbol identifies a listing,
-- and the currency it reports now lands there. A USD claim arriving from a US ADR line can no
-- longer overwrite the IDR of the Jakarta line, because they are different rows.
--
-- DOES NOT: drop `security.currency_code`. Two reasons, both measured:
--
--   1. **15,159 bonds have no listing at all** (12,379 listings against 27,629 securities). A
--      bond's currency comes from its N-PORT filing and belongs to the security, because there is
--      no venue row to hang it on. Deriving the column away would delete a fact for the majority
--      of the universe.
--   2. Every reader — the app, the statements currency gate, `security_market_cap_usd` — selects
--      it today. Changing a column's meaning under live readers in the same migration that
--      introduces the new one is how a schema change becomes an outage.
--
-- So this is the first half: the normalized column exists, is populated, and is what the ingest
-- writes. `security.currency_code` remains for securities with no listing, and
-- `security_currency` below is the single place a reader should ask.

alter table market.listing
  add column if not exists currency_code text references market.currency (code);

comment on column market.listing.currency_code is
  'The quote currency of THIS listing on THIS venue. The normalized fact: Camtek is USD on Nasdaq and ILS on Tel Aviv, and both are true. security.currency_code cannot express that, which is how a provider''s USD claim for a Jakarta listing overwrote its rupiah.';

create index if not exists listing_currency_idx
  on market.listing (currency_code) where currency_code is not null;

-- ── backfill ──────────────────────────────────────────────────────────────────────────────────
--
-- The PRIMARY listing inherits the security's current currency, which after migration 74 has had
-- its impossible values repaired. Non-primary listings are left NULL rather than guessed: we do
-- not know what a secondary line trades in until a fetch tells us, and inventing it would recreate
-- the exact problem this migration exists to remove.
--
-- Idempotent by construction (only fills NULLs), so it needs no one_shot — a later run adds
-- newly-created primary listings and never overwrites a value a fetch has since supplied.
update market.listing l
   set currency_code = s.currency_code
  from market.security s
 where s.security_id = l.security_id
   and l.is_primary
   and l.currency_code is null
   and s.currency_code is not null;

-- ── the single place to ask ───────────────────────────────────────────────────────────────────
--
-- Prefers the PRIMARY listing's currency, falls back to the security's own. The fallback is not a
-- compromise: for a bond there IS no listing, and the filing's `curCd` is the correct and only
-- answer.
drop view if exists market.security_currency;
create view market.security_currency as
select
  s.security_id,
  coalesce(pl.currency_code, s.currency_code) as currency_code,
  case
    when pl.currency_code is not null then 'listing'
    when s.currency_code is not null then 'security'
    else null
  end                                          as source,
  pl.exch_code                                 as venue
from market.security s
left join market.listing pl
  on pl.security_id = s.security_id and pl.is_primary;

comment on view market.security_currency is
  'The one place to ask what currency a security''s figures are in. Prefers the primary LISTING (the normalized fact) and falls back to the security — which is not a compromise, because 15,159 bonds have no listing and their filing currency is the only correct answer. `source` says which was used.';

grant select on market.security_currency to anon, authenticated, service_role;

notify pgrst, 'reload schema';
