-- EVERY RETURN THIS SYSTEM HAS EVER SHOWN IS A PRICE RETURN, AND THAT IS QUIETLY WRONG.
--
-- Not absent — wrong. An absent number renders as "no data" and a reader knows to distrust it; a
-- price return renders as "+4.2%" and is believed. For a market that pays income it understates
-- the answer, and over a 10-year window on a high-yield market the income IS most of the return.
--
-- The dividends were never the blocker. openbb's yfinance provider sets
-- `include_actions: bool = Field(default=True)` and aliases the column, so every price response has
-- carried them and `barFrom` discarded them until deployment#149. This column is what they were for.
--
-- KEPT BESIDE `change_pct`, NEVER INSTEAD OF IT:
--
--   * a CHART draws prices; a RETURN FIGURE wants total. Both are wanted, for the same security,
--     on the same page.
--   * where a security paid nothing in the window the two are IDENTICAL — so an overwrite would
--     look perfectly correct in precisely the cases where it changes nothing, and be wrong
--     everywhere else. That is the shape of a defect that survives review.
--   * `total_return_pct` is NULLABLE on purpose. Null means "not computed for this row" — the
--     scope has no dividend data, or the series was ineligible — and must not be read as 0.
--     Coalescing it to `change_pct` in a view would erase the difference between "no income" and
--     "we do not know", which is the same mistake as labelling an unknown currency with a dollar
--     sign.
--
-- REINVESTED, not summed. `(P_end − P_start + ΣD) / P_start` treats a dividend paid nine years ago
-- as if it had sat in cash. The stored figure compounds each payment from its ex-date, which is
-- what a total-return index means and what anyone comparing against one expects.

alter table market.performance
  add column if not exists total_return_pct numeric;

comment on column market.performance.total_return_pct is
  'Daily-reinvested TOTAL return for the period, in percent. NULL means not computed — no dividend data for this scope, or the series was ineligible — and must never be coalesced to change_pct, which would erase the difference between "paid no income" and "we do not know". Equal to change_pct when the security paid nothing in the window.';

notify pgrst, 'reload schema';
