-- A FIGURE IS LABELLED BY THE FILING, OR NOT AT ALL.
--
-- WHY THIS IS A TEST. This rule has already failed open once, in the caller: the gate was
-- `USD AND country !== 'US'`, Alibaba's FILED country is NULL, NULL is falsy, and the guard
-- declined to fire on the exact security it was built for — while the page rendered CNY
-- 1,023,670,000,000 of revenue as "$1.02T". Migration 66 fixed the country; this moves the whole
-- precedence into the view so a caller cannot re-derive it wrongly.
--
-- The assertions are written against the CALLER'S QUESTION — "what should this figure be labelled
-- with" — not against a column. Asserting `currency is not null` would have passed while the app
-- mislabelled.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('sec','SEC',250) on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.currency (code, name) values ('EUR','Euro')      on conflict (code) do nothing;
insert into market.currency (code, name) values ('CNY','Yuan')      on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('US','United States','US',true)
  on conflict (iso2) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('DE','Germany','DE',true)
  on conflict (iso2) do nothing;

-- A: THE ALIBABA SHAPE — quoted in USD, no FILED country, operating country CN, and a filing that
--    says CNY. The filing must win outright.
insert into market.security (security_id, name, security_type_code, country_iso2, provider_country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000009101', 'T91 Promoted Foreign', 'equity', null, 'CN', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T91A', '00000000-0000-0000-0000-000000009101', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000009101', 'income', date '2025-12-31', 'CNY', '{}'::jsonb, 'sec')
on conflict do nothing;

-- B: THE SAME SHAPE WITHOUT A FILING CURRENCY — quoted USD, no filed country, operating CN.
--    Nothing here knows the reporting currency, so it must be withheld. This is the row the old
--    caller-side gate let through.
insert into market.security (security_id, name, security_type_code, country_iso2, provider_country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000009102', 'T91 Unlabellable', 'equity', null, 'CN', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T91B', '00000000-0000-0000-0000-000000009102', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000009102', 'income', date '2025-12-31', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;

-- C: A GERMAN COMPANY QUOTED IN EUR, no filing currency. The quote currency CAN stand in — a
--    company quoted in its local currency reports in it — so withholding here would lose a label
--    that is correct.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000009103', 'T91 Local Listing', 'equity', 'DE', 'EUR')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T91C', '00000000-0000-0000-0000-000000009103', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000009103', 'income', date '2025-12-31', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;

-- D: AN AMERICAN COMPANY QUOTED IN USD. Ordinary, and must still be labelled.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000009104', 'T91 American', 'equity', 'US', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T91D', '00000000-0000-0000-0000-000000009104', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000009104', 'income', date '2025-12-31', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;

-- E: A PROMOTED AMERICAN COMPANY — no FILED country (it came from the exchange directory, not a
--    filing), operating country US, quoted USD. Under the effective-country rule it is labelled;
--    under a filed-country-only rule it is withheld. Migration 66's entire subject, and without
--    this row a mutation swapping `coalesce(provider, filed)` for `filed` passes clean.
insert into market.security (security_id, name, security_type_code, country_iso2, provider_country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000009105', 'T91 Promoted American', 'equity', null, 'US', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T91E', '00000000-0000-0000-0000-000000009105', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000009105', 'income', date '2025-12-31', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;

-- F: NO COUNTRY AT ALL, quoted USD. The three-valued-logic trap: `country <> 'US'` is NULL here,
--    not true, so a gate written as "USD AND not US -> withhold" never fires and labels it USD.
--    That is the SQL form of the falsy-NULL bug, and only a row with NO country exposes it.
insert into market.security (security_id, name, security_type_code, country_iso2, provider_country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000009106', 'T91 Countryless', 'equity', null, null, 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T91F', '00000000-0000-0000-0000-000000009106', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000009106', 'income', date '2025-12-31', null, '{}'::jsonb, 'yfinance')
on conflict do nothing;

do $$
declare c text;
begin
  select reporting_currency into c from market.security_statement_current
   where security_id='00000000-0000-0000-0000-000000009101';
  if c is distinct from 'CNY' then
    raise exception 'the filing said CNY and the view answers % — the filing''s own reporting currency is authoritative and must beat the quote currency, which is the substitution that rendered CNY 1,023,670,000,000 as "$1.02T"', coalesce(c,'<null>');
  end if;

  select reporting_currency into c from market.security_statement_current
   where security_id='00000000-0000-0000-0000-000000009102';
  if c is not null then
    raise exception 'a non-US company quoted in USD with no filing currency was labelled % — it reports in neither, and this is the exact row the caller-side gate let through because a NULL filed country is falsy', c;
  end if;

  select reporting_currency into c from market.security_statement_current
   where security_id='00000000-0000-0000-0000-000000009103';
  if c is distinct from 'EUR' then
    raise exception 'a German company quoted in EUR was labelled % — a company quoted in its LOCAL currency reports in it, and withholding here loses a label that is correct', coalesce(c,'<null>');
  end if;

  select reporting_currency into c from market.security_statement_current
   where security_id='00000000-0000-0000-0000-000000009104';
  if c is distinct from 'USD' then
    raise exception 'an American company quoted in USD was labelled % — withholding every USD figure is not caution, it is a different wrong answer', coalesce(c,'<null>');
  end if;

  select reporting_currency into c from market.security_statement_current
   where security_id='00000000-0000-0000-0000-000000009105';
  if c is distinct from 'USD' then
    raise exception 'a PROMOTED American company (no filed country, operating US) was labelled % — the rule must use the EFFECTIVE country, the same one security_current answers with, or 21 promoted securities lose a correct label', coalesce(c,'<null>');
  end if;

  select reporting_currency into c from market.security_statement_current
   where security_id='00000000-0000-0000-0000-000000009106';
  if c is not null then
    raise exception 'a security with NO country, quoted USD, was labelled % — `country <> ''US''` is NULL here rather than true, so a gate phrased as a negation never fires; the rule must be written so an unknown country falls through to withheld', c;
  end if;
end $$;

rollback;

\echo 'ok: a figure is labelled by the filing, by a local quote, or not at all'
