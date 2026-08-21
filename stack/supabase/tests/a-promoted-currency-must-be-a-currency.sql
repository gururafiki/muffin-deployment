-- A BACKFILL IS NOT EXERCISED BY AN EMPTY DATABASE.
--
-- Migration 108 promotes `security_fundamentals.raw->>'currency'` onto `market.security`. Applying
-- it to a fresh database matches zero rows, so every guard inside it goes unexercised — which is
-- exactly how migration 38 reached production and broke a deploy. This seeds the production SHAPE
-- and runs the real migration over it.
--
-- The stakes are specific: migrations apply `--single-transaction`, so one value that cannot be
-- cast or one that is silently wrong takes the whole deploy with it or mislabels money for ever.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Promoteland','ZW',false)
  on conflict (iso2) do nothing;

-- GOOD: an ordinary foreign filer. yfinance states the REPORTING currency here — measured, BHP.AX
-- quotes AUD and answers USD — so this is the value the ratio gate depends on.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000010801','T108 Good','equity','ZW'),
  ('00000000-0000-0000-0000-000000010802','T108 Numeric','equity','ZW'),
  ('00000000-0000-0000-0000-000000010803','T108 Junk','equity','ZW'),
  ('00000000-0000-0000-0000-000000010804','T108 Lowercase','equity','ZW')
on conflict (security_id) do nothing;

insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;

insert into market.security_fundamentals (security_id, raw, as_of, source_code) values
  ('00000000-0000-0000-0000-000000010801', '{"currency": "KRW"}', now(), 'yfinance'),
  -- A NUMBER where a code belongs. `->>` renders it as the string "840", which matches nothing a
  -- currency check should accept but would cast cleanly into a text column and read as data.
  ('00000000-0000-0000-0000-000000010802', '{"currency": 840}', now(), 'yfinance'),
  -- The provider's way of saying it does not know. Three characters, so a length check alone
  -- passes it; only requiring LETTERS rejects it.
  ('00000000-0000-0000-0000-000000010803', '{"currency": "n/a"}', now(), 'yfinance'),
  ('00000000-0000-0000-0000-000000010804', '{"currency": "jpy"}', now(), 'yfinance')
on conflict (security_id) do nothing;

-- Run the REAL migration, not a copy of its update — a copy drifts and then proves nothing.
\i /repo/stack/supabase/migrations/108-the-reporting-currency-was-already-here.sql

do $$
declare v text;
begin
  select reporting_currency into v from market.security
   where security_id = '00000000-0000-0000-0000-000000010801';
  if v is distinct from 'KRW' then
    raise exception 'a good currency was not promoted: %', coalesce(v,'<null>');
  end if;

  select reporting_currency into v from market.security
   where security_id = '00000000-0000-0000-0000-000000010802';
  if v is not null then
    raise exception 'a JSON NUMBER was promoted as the currency "%" — it casts cleanly and reads as data', v;
  end if;

  select reporting_currency into v from market.security
   where security_id = '00000000-0000-0000-0000-000000010803';
  if v is not null then
    raise exception '"n/a" was promoted as the currency "%" — three characters is not three letters', v;
  end if;

  -- Case is the provider's business, not ours: `Intl` and every comparison here expect upper.
  select reporting_currency into v from market.security
   where security_id = '00000000-0000-0000-0000-000000010804';
  if v is distinct from 'JPY' then
    raise exception 'a lowercase code was promoted as % — the comparison against the quote currency is case-sensitive', coalesce(v,'<null>');
  end if;
end $$;

rollback;

\echo 'ok: a promoted currency must be a currency'
