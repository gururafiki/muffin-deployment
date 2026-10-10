-- A SECURITY'S QUOTE CURRENCY IS THE ONE THE PRICE LANE SAW ON ITS NEWEST BAR.
--
-- WHY THIS IS A TEST. `security.currency_code` held the reporting currency for many foreign listings
-- (VOD.L EUR where it quotes in pence), and the stock page labelled its price with it. Decided
-- 2026-10-10: the price lane is the one writer of the quote currency, through the label on each
-- bar, recorded per security by `derive_security_price_span`. A newest bar without a label records
-- none, and the readers fall back rather than guess.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.currency (code, name) values ('EUR','Euro'), ('USD','US Dollar'), ('CAD','Canadian Dollar')
  on conflict (code) do nothing;
insert into market.currency (code, name) values ('GBX','Pound sterling, in pence') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZQ','Quoteland','ZQ',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000022001', 'T220 London Line', 'equity', 'ZQ', 'EUR'),
  ('00000000-0000-0000-0000-000000022002', 'T220 Unlabelled',  'equity', 'ZQ', 'CAD')
on conflict (security_id) do nothing;

-- V's newest bar says GBX, where its security says EUR. U's newest bar has no label, and an older
-- one says USD: the older label must not stand in for the newest.
insert into market.price_bar (security_id, trade_date, close, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000022001', date '2026-10-08', 118.35, 'GBX', 'yfinance'),
  ('00000000-0000-0000-0000-000000022001', date '2026-10-09', 119.10, 'GBX', 'yfinance'),
  ('00000000-0000-0000-0000-000000022002', date '2026-10-08',  40.00, 'USD', 'yfinance'),
  ('00000000-0000-0000-0000-000000022002', date '2026-10-09',  41.00,  null, 'yfinance')
on conflict (security_id, trade_date) do nothing;

select market.derive_security_price_span(array['00000000-0000-0000-0000-000000022001',
                                               '00000000-0000-0000-0000-000000022002']::uuid[]);

do $$
declare c text; src text;
begin
  select quote_currency into c from market.security_price_span
   where security_id = '00000000-0000-0000-0000-000000022001';
  if c is distinct from 'GBX' then
    raise exception 'the span records %, expected GBX from the newest bar', coalesce(c, '<null>');
  end if;
  select currency_code, source into c, src from market.security_currency
   where security_id = '00000000-0000-0000-0000-000000022001';
  if c is distinct from 'GBX' or src is distinct from 'price' then
    raise exception 'security_currency says % (from %), expected GBX from the price lane — EUR is the reporting currency',
      coalesce(c, '<null>'), coalesce(src, '<null>');
  end if;
  select quote_currency into c from market.security_current
   where security_id = '00000000-0000-0000-0000-000000022001';
  if c is distinct from 'GBX' then
    raise exception 'security_current.quote_currency is %, expected GBX', coalesce(c, '<null>');
  end if;

  -- An unlabelled newest bar records nothing, and the reader falls back to what it had.
  select quote_currency into c from market.security_price_span
   where security_id = '00000000-0000-0000-0000-000000022002';
  if c is not null then
    raise exception 'the span records % from an OLDER bar while the newest has no label', c;
  end if;
  select currency_code, source into c, src from market.security_currency
   where security_id = '00000000-0000-0000-0000-000000022002';
  if c is distinct from 'CAD' or src is distinct from 'security' then
    raise exception 'with no label on the newest bar, security_currency says % (from %), expected CAD from security',
      coalesce(c, '<null>'), coalesce(src, '<null>');
  end if;

  raise notice '  ok  the quote currency is the one the price lane saw on the newest bar';
end $$;

rollback;

\echo 'ok: the quote currency is the one the price lane saw'
