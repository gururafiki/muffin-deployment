-- THE FILING NOW SAYS WHICH CURRENCY IT IS IN, SO NOTHING SHOULD BE GUESSING.
--
-- Migration 88 got `security_statement.currency` populated from SEC — and it is genuinely
-- multi-currency, which is the whole point. Of the first 522 rows: USD 333, **EUR 111, DKK 30,
-- PEN 24, TWD 24**. Foreign private issuers file 20-F in their own currency, so 36% of those rows
-- would be wrong under a USD default.
--
-- But nothing prefers it yet. `security_statement_current` exposes it only through `st.*`, and the
-- app still labels from `security.currency_code` — the QUOTE currency, which is a different fact.
-- Correct data that nothing consumes.
--
-- ── WHY THE PRECEDENCE BELONGS IN THE VIEW ──────────────────────────────────────────────────
--
-- Migration 66 exists because this exact rule was implemented in the CALLER and failed open on its
-- own headline case: the gate was `USD AND country !== 'US'`, BABA's filed country is NULL, NULL is
-- falsy, and the guard declined to fire on the security it was built for. Moving the rule here
-- means there is one expression, using the same EFFECTIVE country `security_current` answers with,
-- and a caller cannot re-derive it wrongly.
--
-- The rule, in order:
--   1. the filing's own reporting currency, where the provider supplied it — authoritative;
--   2. otherwise the quote currency, but ONLY where it can stand in: a company quoted in its local
--      currency reports in it (SAP.DE in EUR, a German filer);
--   3. otherwise NULL — a non-US company quoted in USD reports in neither, and an unlabelled
--      figure is correct where a guessed one is not.
--
-- APPENDED, not inserted. `create or replace view` can only add columns at the end; every existing
-- reader keeps its column positions. Migration 35 drops this view before recreating it on each
-- pass, which is what lets the append survive a re-run.

create or replace view market.security_statement_current as
select
  sym.symbol,
  st.*,
  s.currency_code,
  coalesce(s.provider_country_iso2, s.country_iso2) as country_iso2,
  -- THE ONE EXPRESSION. Case 2's condition is deliberately the POSITIVE form ("the quote currency
  -- is not USD, or the company is American") rather than the negation that failed open: written
  -- this way a NULL country falls through to NULL, which is the safe answer, instead of sneaking
  -- past a falsy test.
  case
    when st.currency is not null then st.currency
    when s.currency_code is null then null
    when s.currency_code <> 'USD' then s.currency_code
    when coalesce(s.provider_country_iso2, s.country_iso2) = 'US' then s.currency_code
    else null
  end as reporting_currency
from market.security_statement st
join market.security_symbol sym on sym.security_id = st.security_id
join market.security s          on s.security_id = st.security_id;

comment on view market.security_statement_current is
  'Income/balance/cash statements with the security symbol. `reporting_currency` is THE column to label a figure with: the filing''s own currency where a provider supplied it, the quote currency only where it can stand in, and NULL otherwise — a non-US company quoted in USD reports in neither. `currency_code` remains the raw QUOTE currency and `country_iso2` the EFFECTIVE country, so a caller can still see the inputs.';

grant select on market.security_statement_current to anon, authenticated, service_role;

notify pgrst, 'reload schema';
