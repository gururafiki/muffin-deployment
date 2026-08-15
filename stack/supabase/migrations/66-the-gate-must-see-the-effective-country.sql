-- MIGRATION 65 EXPOSED THE FILED COUNTRY, AND THE GATE BUILT ON IT FAILS OPEN ON ALIBABA.
--
-- 65 appended `country_iso2` to `security_statement_current` so a caller could tell whether
-- `currency_code` is also the REPORTING currency — a non-US company quoted in USD gets no label,
-- because an ADR does not report in the currency it trades in. That is right, and it took the
-- column from the wrong place: `s.country_iso2` is the FILED country, from N-PORT.
--
-- BABA has no filed country at all. It entered the universe through `promote-listing`, which builds
-- a security from an OpenFIGI mapping and has no filing to read, so `country_iso2` is NULL and
-- `provider_country_iso2` is CN. `security_current` already knows this and answers CN, because it
-- coalesces the two — this view did not.
--
-- The consequence is precise and was measured, not reasoned about: the caller's test is
-- `currency is USD AND country is not US`, a NULL country is falsy, so the gate declines to fire
-- and **labels Alibaba's CNY revenue as USD** — the exact figure the whole change exists to stop
-- rendering as $1.02 TRILLION. A guard that fails open on its own headline case is worse than none,
-- because it is now believed.
--
-- 21 securities have statements, are quoted in USD, and have no filed country: every one of them
-- promoted from the exchange directory rather than ingested from a filing, which is a population
-- that only exists since `promote-listing` got a button.
--
-- So the view answers with the EFFECTIVE country, the same coalesce `security_current` uses. The
-- column keeps its name and position, and `create or replace view` permits changing the expression
-- behind it — only renaming, reordering and dropping are forbidden.

create or replace view market.security_statement_current as
select
  sym.symbol,
  st.*,
  s.currency_code,
  -- EFFECTIVE, not filed. A security promoted from the directory has no filing and therefore no
  -- `country_iso2`; its operating country is the only one it has. `security_current` resolves it
  -- the same way, and the two must not disagree about where a company is.
  coalesce(s.provider_country_iso2, s.country_iso2) as country_iso2
from market.security_statement st
join market.security_symbol sym on sym.security_id = st.security_id
join market.security s          on s.security_id = st.security_id;

comment on view market.security_statement_current is
  'Income/balance/cash statements with the security symbol. `currency_code` is the QUOTE currency and is only the reporting currency for a LOCAL listing; `country_iso2` is the EFFECTIVE country (operating, falling back to filed) so a caller can tell the two apart. A non-US company quoted in USD reports in neither, and must not be labelled.';

grant select on market.security_statement_current to anon, authenticated, service_role;

notify pgrst, 'reload schema';
