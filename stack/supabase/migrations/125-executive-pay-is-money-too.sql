-- EXECUTIVE PAY IS MONEY, AND MONEY MUST CARRY ITS CURRENCY.
--
-- `security_leadership` serves `pay` as a bare number. SK hynix's chief executive is stored as
-- 4,239,000,000 — which is KRW, about $3m. Rendered with the `$` this app used to hardcode it reads
-- as **four billion dollars**. This is the Alibaba shape exactly (CNY 1,023,670,000,000 of revenue
-- printed as "$1.02T"), and pay is if anything the more dangerous field: a CHF 8m Swiss package
-- shown as $8m is plausible, wrong, and nothing about it invites a second look.
--
-- The rule is not re-derived here. Migration 091 already wrote THE expression for "what currency
-- should this figure be labelled with", and the point of reusing it is that two views cannot then
-- disagree about one company. It is written in the POSITIVE form deliberately: `currency <> 'USD'`
-- is NULL — not true — when the currency is unknown, so the negation this codebase shipped once
-- before failed open on precisely the security it was built for.
--
-- The order differs from 091's in one place, and on purpose. A statement is labelled by the FILING
-- first, because the filing states its own currency. There is no filing here: a pay figure comes
-- from the same yfinance company response that `security.reporting_currency` was promoted out of
-- (migration 108), so the company's stated reporting currency is the primary source rather than the
-- fallback. The quote currency stands in only where it can, and NULL means WITHHOLD — an unlabelled
-- number is the honest render, and defaulting to dollars is how the original bug started.
--
-- Measured 2026-08-22 over the 94 securities that currently have officers: every one resolves to a
-- currency (USD/US, KRW/KR, EUR across AT/ES/IT/IE/GR, NZD/NZ, MYR/MY), so the withheld branch is
-- unexercised in production today. It stays because the case it covers — a non-US company quoted in
-- USD with no reporting currency — is exactly the one that arrives silently.

drop view if exists market.security_leadership;
create view market.security_leadership as
select
  o.security_id,
  o.name,
  o.title,
  o.pay,
  o.age,
  o.fiscal_year,
  -- THE CHIEF EXECUTIVE FIRST, then the rest by pay. A list ordered by pay alone puts whoever was
  -- granted the most equity that year at the top, which is not who runs the company.
  (o.title ilike '%chief executive%' or o.title ilike '%CEO%') as is_ceo,
  -- THE LABEL FOR `pay`. NULL means the caller must render the number unlabelled or not at all.
  case
    when s.reporting_currency is not null then s.reporting_currency
    when s.currency_code is null then null
    when s.currency_code <> 'USD' then s.currency_code
    when coalesce(s.provider_country_iso2, s.country_iso2) = 'US' then s.currency_code
    else null
  end as pay_currency
from market.security_officer o
join market.security s on s.security_id = o.security_id;

comment on view market.security_leadership is
  'Officers with a flag for the chief executive and the currency `pay` is denominated in. Ordering by pay alone puts whoever was granted the most equity that year at the top, which is not who runs the company. `pay_currency` follows migration 091''s rule — the company''s stated reporting currency first, the quote currency only where it can stand in, NULL otherwise — so a figure whose currency is unknown is rendered unlabelled rather than as dollars.';

grant select on market.security_leadership to anon, authenticated, service_role;

notify pgrst, 'reload schema';
