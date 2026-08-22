-- A BARE TICKER IS NOT A US LISTING, AND 62% OF THE BACKLOG WAS UNANSWERABLE.
--
-- Migration 123 stopped feeding alpha_vantage suffixed foreign symbols (`ASML.AS`) by taking the US
-- TICKER and rejecting anything containing a dot. That was right and it was not enough: OpenFIGI's
-- US lookup hands this pipeline the thin OTC FOREIGN-ORDINARY line for most foreign companies —
-- `ASMLF`, `BUDFF`, `ICTEF`, `NOKBF`, `TSMWF` — which are bare tickers, so they sailed through the
-- suffix filter and alpha_vantage does not carry a single one of them.
--
-- Measured 2026-08-22, seconds apart on one key: `ASMLF` returns `{}` — an object with ZERO keys —
-- while `ASML` returns 108 quarters and `MSFT` 122. The empty object is a statement about the
-- SYMBOL; the quota and the endpoint were both fine.
--
-- ── WHY THIS IS A BUDGET PROBLEM AND NOT A TIDINESS ONE ────────────────────────────────────────
--
-- The free tier is 25 calls a DAY and the warm-up cron spends 24 of them (8 runs x 3). Of the 1,015
-- securities in the backlog, 621 have no US listing at all — so at three calls a run this resource
-- would have spent TWENTY-SIX DAYS learning, one call at a time, that an OTC line it should never
-- have asked about is an OTC line. Every one of those calls is 4% of a day's budget.
--
-- ── THE FILTER IS THE VENUE WE RECORDED, NOT THE SHAPE OF THE SYMBOL ───────────────────────────
--
-- The obvious filter is the `F` suffix, and it is the wrong one — `security-symbol-repair` already
-- records why pattern-matching a symbol rewrites working ones (`SAND.ST`, `ALFA.ST` and `TELIA.ST`
-- all look like share classes and are whole company names). `market.listing` already holds the
-- venue, so the question "does this company trade in the US" is data we have rather than a guess
-- from spelling.
--
-- ANY US listing, not the PRIMARY one: an ADR is exactly the case this must keep, and a Taiwanese
-- company whose ADR is servable is the reason 123 tests the symbol rather than the country. It
-- happens that only 10 of 394 differ — TSM's US line is already flagged primary — but the
-- inclusive test is the one that stays right when that flag is wrong.
--
-- Verified against the top 400 by weight before shipping: of the 233 excluded, every single one is
-- a foreign-ordinary line whose only venue is foreign (Amsterdam, Manila, Helsinki, Taipei, Milan,
-- Dublin). No US company is dropped.
--
-- ── AND A CORRECTION, BECAUSE THE FIRST VERSION OF THIS COMMENT OVERSTATED IT ──────────────────
--
-- I wrote that each excluded company is separately held under the row carrying its US listing,
-- having checked `ASMLF`/`ASML` and `TSMWF`/`TSM`. Measured properly afterwards: of the top 40
-- excluded by weight, only **2** have a US-listed sibling. The two I checked were the exception.
-- That is this file's own "probe an endpoint with symbols you expect to FAIL" rule, ignored while
-- writing the rule down.
--
-- The DECISION is unchanged, because the excluded rows cannot answer either way: AB InBev is held
-- only as `BUDFF` (its US rows are BONDS — `ANHEUSER-BUSCH INBEV WOR`/`FIN`, no symbol), Novo
-- Nordisk only as `NONOF`, and alpha_vantage returns `{}` for those spellings. The filter spends no
-- call to learn it; it does not create the gap.
--
-- But the gap is REAL and worth naming: ~610 large holdings have no symbol this pipeline holds that
-- alpha_vantage can serve. Closing it means resolving the ADR — `NVO` for Novo Nordisk, `BUD` for
-- AB InBev — which is a symbol-resolution problem, not an EPS one, and is deliberately not
-- attempted here.
--
-- This is a bound, not a guarantee: a US-listed name whose `listing` row we never recorded still
-- gets asked and now gets MARKED rather than re-asked for ever, which is the half of this fix that
-- lives in `security-eps-history`.

drop view if exists market.pending_eps_history;
create view market.pending_eps_history as
select
  s.security_id,
  t.value as symbol,
  max(h.weight) as best_weight
from market.security s
join market.fund_holding_current h on h.security_id = s.security_id
join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
where s.security_type_code = 'equity'
  -- A US LISTING HAS NO EXCHANGE SUFFIX (migration 123). Kept: it is cheap and it catches a
  -- malformed identifier that the venue test below would let through.
  and t.value not like '%.%'
  -- ...AND A BARE TICKER IS STILL NOT A US LISTING. This is the half 123 was missing.
  and exists (
    select 1 from market.listing l
    where l.security_id = s.security_id and l.exch_code = 'US'
  )
  and (s.eps_history_fetched_at is null
       or s.eps_history_fetched_at < now() - interval '90 days')
group by s.security_id, t.value
-- THE TIGHTEST BOUND IN THE SCHEMA, and it has to be. 25 calls a DAY is ~9,000 a year; the top
-- holdings refreshed quarterly is ~2,000 of them. A looser threshold does not drain slower, it
-- exhausts the day's quota on the first cron run and fails every page-open after it.
having max(h.weight) >= 1.0
order by max(h.weight) desc;

comment on view market.pending_eps_history is
  'US-LISTED equities that are at least 1% of some tracked fund and whose EPS history is unread or a quarter old. Takes the US ticker and requires a US listing in market.listing: alpha_vantage serves US listings, and OpenFIGI''s US lookup returns the OTC foreign-ordinary line (ASMLF, TSMWF) for most foreign companies — bare tickers the provider answers with an empty object, each costing 4% of a 25-a-day budget to learn nothing.';

grant select on market.pending_eps_history to service_role;

notify pgrst, 'reload schema';
