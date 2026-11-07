-- A NET SHARE COUNT ALONE MISREPRESENTS WHAT INSIDERS DID.
--
-- One officer exercising a large option grant can outweigh a dozen colleagues buying. A summary
-- that reports only net shares would call that "selling" — the arithmetic is right and the
-- statement is wrong. `security_insider_summary` therefore counts PEOPLE on each side as well, and
-- this test makes the two answers DISAGREE so a summary that dropped the people count could not
-- pass.
--
-- Every fixture row names its filing, because since 2026-11-07 the summary counts only those.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-form4','SEC Form 4',240)
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Insiderland','ZW',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000011601','T116 Filer','equity','ZW','0000000116'),
  ('00000000-0000-0000-0000-000000011602','T116 Not a filer','equity','ZW', null)
on conflict (security_id) do nothing;

-- FOUR BUYERS, ONE SELLER, AND THE SELLER IS BIGGER. Net shares say "selling"; the people say the
-- opposite. A fixture where both agree could not tell the two summaries apart.
insert into market.insider_trade
  (trade_key, security_id, transaction_date, owner_name, direction, shares, source_code,
   accession_number, line_key) values
  -- ADA TRADES TWICE, deliberately: with one trade each, `count(*)` and `count(distinct owner)`
  -- return the SAME number and a summary that dropped the people count would pass unnoticed.
  ('k1','00000000-0000-0000-0000-000000011601', current_date - 5,  'Ada',   'Acquisition', 1000, 'sec-form4', '0000000116-26-k1', 'nd:1'),
  ('k1b','00000000-0000-0000-0000-000000011601', current_date - 4, 'Ada',   'Acquisition', 1000, 'sec-form4', '0000000116-26-k1b', 'nd:1'),
  ('k2','00000000-0000-0000-0000-000000011601', current_date - 6,  'Grace', 'Acquisition', 1000, 'sec-form4', '0000000116-26-k2', 'nd:1'),
  ('k3','00000000-0000-0000-0000-000000011601', current_date - 7,  'Alan',  'Acquisition', 1000, 'sec-form4', '0000000116-26-k3', 'nd:1'),
  ('k4','00000000-0000-0000-0000-000000011601', current_date - 8,  'Edsger','Acquisition', 1000, 'sec-form4', '0000000116-26-k4', 'nd:1'),
  ('k5','00000000-0000-0000-0000-000000011601', current_date - 9,  'Tony',  'Disposition', 50000,'sec-form4', '0000000116-26-k5', 'nd:1'),
  -- OUTSIDE THE 90-DAY WINDOW: a trade from last year must not be counted as current direction.
  ('k6','00000000-0000-0000-0000-000000011601', current_date - 200,'Ada',   'Acquisition', 9999, 'sec-form4', '0000000116-26-k6', 'nd:1')
on conflict (trade_key) do nothing;

do $$
-- Prefixed, because a plpgsql variable named like a selected column is AMBIGUOUS and the
-- error names the column rather than the shadowing.
declare v_b integer; v_s integer; v_buyers integer; v_sellers integer; v_net numeric; n integer;
begin
  select buys, sells, buyers, sellers, net_shares
    into v_b, v_s, v_buyers, v_sellers, v_net
    from market.security_insider_summary
   where security_id = '00000000-0000-0000-0000-000000011601';

  -- 1. THE 90-DAY WINDOW HOLDS. Six rows exist; only five are recent.
  if v_b <> 5 or v_s <> 1 then
    raise exception 'the window counted % buys and % sells, expected 5 and 1 — a trade from 200 days ago is not current direction', v_b, v_s;
  end if;

  -- 2. NET SHARES SAY SELLING. This is the number a simpler summary would report alone.
  if v_net >= 0 then
    raise exception 'net shares came out %, expected negative — the fixture must make the two answers DISAGREE or it cannot tell them apart', v_net;
  end if;

  -- 3. AND THE PEOPLE SAY THE OPPOSITE. FIVE buy trades but FOUR distinct buyers — the two numbers
  --    differ on purpose, so a summary counting rows instead of people gives 5 here and fails.
  --    Four people buying against one selling: reporting only net shares would say "insiders sold"
  --    about a company four of them were buying.
  if v_buyers <> 4 or v_sellers <> 1 then
    raise exception 'the summary counted % buyers and % sellers, expected 4 and 1', v_buyers, v_sellers;
  end if;
end $$;

rollback;

\echo 'ok: insider direction counts people, not just shares'
