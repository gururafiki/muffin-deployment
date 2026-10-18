-- A ONE-SYMBOL STATEMENTS READ READS ONE SECURITY'S STATEMENTS.
--
-- WHY. The stock page reads `security_statement_current` one symbol at a time (muffin-ui
-- `use-statements.ts`: income statements, newest four). The view joined `market.security_symbol`,
-- which resolves each security's symbol with LATERAL subqueries, so the symbol filter could not
-- narrow anything before the join. Measured on 2026-10-18:
--   * as `postgres`, warm, a read of AAPL scanned every income statement (85,597 rows) and resolved
--     all 27,977 securities in a nested loop, in 407 ms;
--   * as anon over PostgREST, best of three: AAPL 0.66 s, MSFT 0.85 s, 7203.T 0.65 s, VOD.L 0.84 s;
--   * `check_anon_read_latency.py` read it at 1,993 ms right after a deploy, against its 2,000 ms
--     budget and anon's 3 s ceiling.
-- The cost grows with `security_statement`, which the company lane's first rotation adds about
-- 44,600 rows to a day until 2026-10-24. Umbrella note:
-- docs/deferred/2026-10-18-the-statements-read-resolves-every-symbol.md.
--
-- This is the shape CLAUDE.md records as "resolving a symbol through `security_symbol` costs a scan
-- of the whole universe". `price_series` (migration 102) and `security_ratio_series` (#437) moved to
-- `market.symbol_security`, the materialised map with an index on the symbol. This view now does
-- too.
--
-- WHAT IT CHANGES, measured. `symbol_security` is defined as the rows of `security_symbol` with a
-- symbol, one per security (12,402 = 12,402 on 2026-10-18, 0 differing), and `security_symbol`
-- itself excludes a security with no symbol. So the rows are the same: compared in a rolled-back
-- transaction on production, AAPL, MSFT, 7203.T, VOD.L, 005930.KS, SAP.DE, NVDA and BRK-B differ
-- by 0 rows either way. The one difference is freshness: the matview is rebuilt with the facets, so
-- a symbol that changes appears under its new name after the next refresh, as it already does on
-- the price and ratio charts. Only two readers exist, both filtering by symbol: the app's hook and
-- the latency guard. No view depends on this one.
--
-- The app's read went from ~250 ms to ~1 ms on the server: an index scan of the symbol, then the
-- security, then its income statements.
--
-- Guard: tests/a-one-symbol-statements-read-reads-one-security.sql counts the rows the read touches,
-- since on a fixture every plan finishes in milliseconds.
--
-- AND THE VIEW'S OTHER TESTS BECAME SNAPSHOT TESTS. A fixture's securities are invisible to a
-- materialised view until it is rebuilt, so both tests reading this view now refresh
-- `symbol_security` after their inserts. One of them would otherwise have kept passing on nothing:
-- the-gate-must-see-the-effective-country.sql asserts that no row disagrees, which an empty view
-- satisfies, so it also gained a floor (all three fixture securities must be seen). The other,
-- a-figure-is-labelled-by-the-filing.sql, failed loudly, which is how this was found.

create or replace view market.security_statement_current as
select sym.symbol,
       st.security_id,
       st.statement,
       st.period_ending,
       st.period_type,
       st.currency,
       st.data,
       st.source_code,
       st.as_of,
       st.derived_at,
       s.currency_code,
       coalesce(s.provider_country_iso2, s.country_iso2) as country_iso2,
       case
         when st.currency is not null then st.currency
         when s.currency_code is null then null::text
         when s.currency_code <> 'USD'::text then s.currency_code
         when coalesce(s.provider_country_iso2, s.country_iso2) = 'US'::text then s.currency_code
         else null::text
       end as reporting_currency
  from market.security_statement st
  join market.symbol_security sym on sym.security_id = st.security_id
  join market.security s on s.security_id = st.security_id;
