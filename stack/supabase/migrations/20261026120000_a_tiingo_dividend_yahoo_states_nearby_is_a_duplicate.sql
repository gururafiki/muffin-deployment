-- A TIINGO DIVIDEND THAT YAHOO STATES A FEW DAYS AWAY IS THE SAME DIVIDEND, COUNTED TWICE.
--
-- Decided by the user 2026-10-25 (umbrella docs/deferred/2026-10-25-tiingo-dividends-are-not-split-
-- adjusted.md): Yahoo's rows replace Tiingo's wherever Yahoo's documents state the dividend, and only
-- the 133 rows Yahoo does not cover stay until the contract (80 Tiingo-only and 42 out-of-span
-- dividends, 11 "splits"). The Yahoo writer replaced Tiingo's row only on the SAME ex-date
-- (muffin-ingest#126), because `security_corporate_action` is keyed on the date. The note's
-- "within 5 days" category, 141 dividends Yahoo states a day or a few days apart, was left beside
-- Yahoo's row, so `security_return` reinvests both.
--
-- Measured 2026-10-26: 142 Tiingo dividends in 42 securities have a Yahoo dividend within five days,
-- for example AT&T, Tiingo 0.2775 on 2026-10-12 and Yahoo 0.2780 on 2026-10-09. Five days cannot
-- reach a separate payment: the most frequent payers here are monthly.
--
-- After it, `security_return` re-derives from the remaining rows (materialised by hand once). The
-- nightly backup holds the deleted rows.

delete from market.security_corporate_action t
 where t.source_code = 'tiingo'
   and t.kind = 'dividend'
   and exists (select 1 from market.security_corporate_action y
                where y.security_id = t.security_id
                  and y.kind = 'dividend'
                  and y.source_code = 'yfinance'
                  and y.ex_date between t.ex_date - 5 and t.ex_date + 5);
