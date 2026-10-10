-- A MARKET CAP IS CONVERTED AND LABELLED BY ITS OWN CURRENCY, NEVER BY A GUESS BESIDE IT.
--
-- WHY THIS IS A TEST. `security_market_cap_usd` multiplied `security.market_cap` by the rate of
-- `security.currency_code`, and that column held the REPORTING currency (Yahoo's `financialCurrency`,
-- measured 2026-10-10), while a cap is stated in the quote currency's unit. A wrong rate produces a
-- plausible number in every reader at once: cap bands, style, peers, the cap-weighted aggregates.
-- Since 2026-10-10 the cap lives on `security_fundamentals` with its own currency, and the old pair is
-- only a fallback for a security the company lane has not visited.
--
-- The fixture makes the two rules disagree: the fresh cap is in JPY while the legacy label beside the
-- legacy cap says EUR, at rates that give different dollars.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar'), ('EUR','Euro'), ('JPY','Yen')
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZC','Capland','ZC',false)
  on conflict (iso2) do nothing;
insert into market.fx_rate (currency_code, as_of, usd_per_unit, source_code) values
  ('EUR', date '2026-10-09', 1.10, 'yfinance'),
  ('JPY', date '2026-10-09', 0.0067, 'yfinance')
on conflict do nothing;

-- A: visited by the company lane. Fresh cap 15,000 JPY; the legacy pair says 100 EUR.
-- B: not visited yet. A fundamentals row exists (the edge wrote it) with no cap: the legacy pair stands.
insert into market.security (security_id, name, security_type_code, country_iso2, market_cap, currency_code) values
  ('00000000-0000-0000-0000-000000020001', 'T200 Visited', 'equity', 'ZC', 100, 'EUR'),
  ('00000000-0000-0000-0000-000000020002', 'T200 Not Yet', 'equity', 'ZC', 50, 'EUR')
on conflict (security_id) do nothing;
insert into market.security_fundamentals (security_id, source_code, as_of, market_cap, market_cap_currency) values
  ('00000000-0000-0000-0000-000000020001', 'yfinance', now(), 15000, 'JPY'),
  ('00000000-0000-0000-0000-000000020002', 'yfinance', now(), null, null)
on conflict (security_id) do nothing;
insert into market.instruments (symbol, security_id, currency, market_cap) values
  ('T200A', '00000000-0000-0000-0000-000000020001', 'EUR', 1)
on conflict do nothing;

do $$
declare usd numeric; cur text; src text; native numeric;
begin
  -- 1. THE FRESH CAP IS CONVERTED BY ITS OWN CURRENCY: 15,000 x 0.0067 = 100.5, not 100 x 1.10.
  select market_cap_usd, currency_code, cap_source into usd, cur, src
    from market.security_market_cap_usd where security_id = '00000000-0000-0000-0000-000000020001';
  if usd is distinct from 100.5 or cur is distinct from 'JPY' or src is distinct from 'fundamentals' then
    raise exception 'the fresh cap converts to % % (source %), expected 100.5 JPY from fundamentals — '
      'a cap converted at another currency''s rate is wrong everywhere it is read', usd, cur, src;
  end if;

  -- 2. UNTIL THE LANE VISITS, THE OLD PAIR STANDS: 50 x 1.10 = 55.
  select market_cap_usd, currency_code, cap_source into usd, cur, src
    from market.security_market_cap_usd where security_id = '00000000-0000-0000-0000-000000020002';
  if usd is distinct from 55.0 or cur is distinct from 'EUR' or src is distinct from 'security' then
    raise exception 'the fallback converts to % % (source %), expected 55 EUR from security', usd, cur, src;
  end if;

  -- 3. THE STOCK PAGE'S CAP AND ITS LABEL COME FROM THE SAME PLACE.
  select market_cap, market_cap_currency into native, cur
    from market.security_current where security_id = '00000000-0000-0000-0000-000000020001';
  if native is distinct from 15000 or cur is distinct from 'JPY' then
    raise exception 'security_current shows % labelled %, expected 15000 JPY', native, cur;
  end if;
  select market_cap, market_cap_currency into native, cur
    from market.instrument_current where symbol = 'T200A';
  if native is distinct from 15000 or cur is distinct from 'JPY' then
    raise exception 'instrument_current shows % labelled %, expected 15000 JPY — its `currency` '
      'column is the security''s, not the cap''s', native, cur;
  end if;

  -- 4. A CAP IS NEVER STORED WITHOUT ITS CURRENCY.
  begin
    update market.security_fundamentals set market_cap_currency = null
     where security_id = '00000000-0000-0000-0000-000000020001';
    raise exception 'a cap was stored without its currency';
  exception when check_violation then null;
  end;
  raise notice '  ok  a market cap is converted and labelled by its own currency';
end $$;

rollback;

\echo 'ok: a market cap is converted and labelled by its own currency'
