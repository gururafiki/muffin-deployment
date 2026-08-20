-- ALIBABA'S REVENUE IS LABELLED USD AND IS DENOMINATED IN CNY. 376 securities can be wrong this way.
--
-- Found by auditing ingested VALUES rather than coverage, 2026-08-14. `security_statement_current`
-- exposes `security.currency_code` as the statement label, because the income/balance/cash
-- endpoints carry no currency field of their own — migration 35 says so and calls it "the honest
-- label ... for all but a handful of cross-listed names".
--
-- The handful is 376, and it includes one of the largest companies on earth. Measured:
--
--   BABA   revenue 1,023,670,000,000  labelled USD  -> would read $1.02 TRILLION, larger than
--          Walmart, against a true ~$141bn. The figure is CNY.
--   XIACF  revenue   457,286,687,000  labelled USD  -> Xiaomi, also CNY
--   ITUB   revenue   165,243,000,000  labelled USD  -> Itaú, BRL
--
-- `currency_code` is the QUOTE currency and it is CORRECT as that: BABA really does trade in USD on
-- the NYSE, and its price, market cap and returns are all right. A US listing of a foreign company
-- simply does not report its accounts in the currency it trades in — and 565 securities in this
-- universe are a non-US company quoted in USD, 376 of them with statements.
--
-- It is right for every LOCAL listing, which is why this is a narrow exposure and not a rewrite:
-- 7203.T is JPY, 005930.KS is KRW, SAP.DE is EUR, NESN.SW is CHF, and in each case the accounts
-- are in that currency too.
--
-- THERE IS NO SOURCE FOR THE REPORTING CURRENCY HERE, and I looked before concluding that:
--
--   * the statement endpoints carry no currency field (migration 29's `reported_currency` was a
--     wrong guess, and `security_statement.currency` is null on all 83,211 rows — measured)
--   * `equity/fundamental/metrics` carries `currency`, which is the QUOTE currency again
--   * Yahoo's chart meta gives `currency: USD` for BABA, ITUB, VALE — quote currency
--   * `quoteSummary`'s `financialCurrency` is the real answer and returns
--     `Unauthorized: Invalid Crumb`
--   * deriving it from `enterprise_to_revenue` DOES NOT WORK: Yahoo computes that ratio within the
--     reporting currency, so BABA comes back 1.00 — and the same derivation produces false
--     positives on VALE (0.18) and 005930.KS (0.69). Tested and discarded.
--
--   A country->currency guess is also wrong: CN->CNY suits Alibaba and Xiaomi, and VALE and NU are
--   Brazilian companies that genuinely report in USD.
--
-- So the view stops answering a question it cannot answer, and exposes what it DOES know instead.
-- `country_iso2` is appended and the caller decides: a foreign company quoted in USD gets NO
-- currency label rather than a wrong one. That is this schema's existing rule, stated in
-- `money.ts` — "with no currency the figure is left UNLABELLED — defaulting to dollars is how the
-- bug started" — applied to the case that still defaulted.
--
-- APPENDED, not restructured: `create or replace view` can add a column and cannot rename, reorder
-- or drop one, so every existing reader is untouched.

create or replace view market.security_statement_current as
select
  sym.symbol,
  st.*,
  s.currency_code,
  -- The caller needs this to know whether `currency_code` can be trusted as the REPORTING currency.
  -- A US listing of a foreign company reports in neither its quote currency nor, necessarily, its
  -- home one — so the only honest label for that case is none.
  s.country_iso2
from market.security_statement st
join market.security_symbol sym on sym.security_id = st.security_id
join market.security s          on s.security_id = st.security_id;

comment on view market.security_statement_current is
  'Income/balance/cash statements with the security symbol. `currency_code` is the QUOTE currency and is only the reporting currency for a LOCAL listing — for a non-US company quoted in USD (376 securities, Alibaba among them) the accounts are in some other currency and no source here can say which, so the caller must not label them.';

grant select on market.security_statement_current to anon, authenticated, service_role;

notify pgrst, 'reload schema';
