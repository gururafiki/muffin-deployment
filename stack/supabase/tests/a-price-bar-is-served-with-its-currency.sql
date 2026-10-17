-- A PRICE BAR IS SERVED WITH ITS CURRENCY, NEVER WITH THE SECURITY'S.
--
-- WHY THIS IS A TEST. The stock page names the chart's currency from these rows (Phase 4 decision
-- 20). The security's own `currency_code` is a legacy guess, often the REPORTING currency, and it
-- read `EUR` over Vodafone's pence and `USD` over Lenovo's Hong Kong dollars
-- (migration 20261017170000).
--
-- WHAT MAKES THE RULES DISAGREE. The security says EUR and its bars say GBX; the second security
-- says USD and its bars say nothing. Serving the security's column gives EUR and USD; serving the
-- bar's gives GBX and null. Both grains are asserted. In an older week, beyond the daily arm, a
-- bar labelled GBP precedes the GBX bar whose close the weekly row serves, as across a unit break,
-- so a weekly arm that took any other bar's label fails too.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-xbrl','SEC XBRL',275) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.currency (code, name) values ('USD','US Dollar'), ('EUR','Euro'), ('GBP','Pound sterling'),
  ('GBX','Pound sterling, in pence') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('XQ','Quoteland','XQ',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, currency_code) values
  ('00000000-0000-0000-0000-000000044001', 'T440 Pence, reports in euros', 'equity', 'XQ', 'EUR'),
  ('00000000-0000-0000-0000-000000044002', 'T440 Unlabelled',              'equity', 'XQ', 'USD')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T440P', '00000000-0000-0000-0000-000000044001', 'sec-xbrl'),
  ('ticker', 'T440U', '00000000-0000-0000-0000-000000044002', 'sec-xbrl')
on conflict (kind_code, value) do nothing;

-- A Tuesday and a Wednesday of one week, too old for the daily arm, then a bar both arms serve.
insert into market.price_bar (security_id, trade_date, close, source_code, currency_code) values
  ('00000000-0000-0000-0000-000000044001', date '2025-03-04',   1.167, 'yfinance', 'GBP'),
  ('00000000-0000-0000-0000-000000044001', date '2025-03-05', 116.7,   'yfinance', 'GBX'),
  ('00000000-0000-0000-0000-000000044001', current_date - 10, 116.7,   'yfinance', 'GBX'),
  ('00000000-0000-0000-0000-000000044002', current_date - 10,  31.1, 'yfinance', null)
on conflict (security_id, trade_date) do nothing;

refresh materialized view market.symbol_security;

do $$
declare n integer; c text;
begin
  -- 1. THE BAR'S LABEL, ON BOTH GRAINS. EUR would be the security's guess.
  select count(*) into n from market.price_series where symbol = 'T440P';
  if n <> 3 then
    raise exception 'the pence line has % rows, expected 3 (the old week''s weekly row, the recent bar daily and weekly) — the fixture no longer exercises the view', n;
  end if;
  select count(*) into n from market.price_series where symbol = 'T440P' and currency_code is distinct from 'GBX';
  if n <> 0 then
    select string_agg(grain || '=' || coalesce(currency_code, '<null>'), ', ') into c
      from market.price_series where symbol = 'T440P';
    raise exception 'the pence line is served as %, expected GBX on both grains. EUR is the security''s legacy currency, the reporting currency the edge wrote', c;
  end if;

  -- 2. NO LABEL, NO CURRENCY. USD would be the security's guess.
  select count(*) into n from market.price_series where symbol = 'T440U' and currency_code is not null;
  if n <> 0 then
    raise exception '% rows of an unlabelled line carry a currency — a bar with no label must serve null, not the security''s guess', n;
  end if;
  select count(*) into n from market.price_series where symbol = 'T440U';
  if n <> 2 then
    raise exception 'the unlabelled line has % rows, expected 2: a missing label is a missing currency, not a missing bar', n;
  end if;

  raise notice '  ok  a price bar is served with its own currency on both grains, and an unlabelled one with none';
end $$;

rollback;

\echo 'ok: a price bar is served with its currency'
