-- AN INSIDER TRADE TWO WRITERS RECORD IS COUNTED ONCE.
--
-- `insider_trade` is written by the edge `security-insider` resource (no accession) and by the
-- Dagster SEC lanes (with one). The summary must count a trade both record once, keep an edge row
-- for a day the lane has not collected, and judge a day across all securities, because the two
-- writers can date one filing on either side of a day boundary.
--
-- THE FIXTURE MAKES FOUR RULES DISAGREE about security T1, whose answer is 2 buys, 1 sell, 3 trades:
--   - count every row (the old view):                 3 buys, 2 sells, 5 trades;
--   - count only the lane's rows:                     1 buy,  1 sell,  2 trades (Grace is lost);
--   - drop an edge row only where the SAME security
--     has a lane row that day:                        2 buys, 2 sells, 4 trades (Alan twice);
--   - drop an edge row on any day the lane collected: 2 buys, 1 sell,  3 trades.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-form4','SEC Form 4',240)
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Insiderland','ZW',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000030001','T1 Two writers','equity','ZW', 300001),
  ('00000000-0000-0000-0000-000000030002','T2 Lane only','equity','ZW', 300002)
on conflict (security_id) do nothing;

insert into market.insider_trade
  (trade_key, security_id, filing_date, transaction_date, owner_name, direction, shares,
   source_code, accession_number, line_key) values
  -- 1. ONE TRADE, BOTH WRITERS, ONE DAY (current_date - 10). Counted once.
  ('e-ada', '00000000-0000-0000-0000-000000030001', current_date - 10, current_date - 11,
   'Ada', 'Acquisition', 100, 'sec-form4', null, null),
  ('l-ada', '00000000-0000-0000-0000-000000030001', current_date - 10, current_date - 11,
   'Ada', 'Acquisition', 100, 'sec-form4', '0000300001-26-000010', 'nd:1'),
  -- 2. AN EDGE ROW ON A DAY THE LANE HAS NOT COLLECTED (current_date - 20; no lane row for anyone).
  ('e-grace', '00000000-0000-0000-0000-000000030001', current_date - 20, current_date - 21,
   'Grace', 'Acquisition', 200, 'sec-form4', null, null),
  -- 3. ONE FILING ACROSS A DAY BOUNDARY. The edge dates it current_date - 30, the lane - 29 (its
  -- index day). The lane collected - 30 too, but only T2 filed then, so T1 has no lane row that day.
  ('e-alan', '00000000-0000-0000-0000-000000030001', current_date - 30, current_date - 31,
   'Alan', 'Disposition', 300, 'sec-form4', null, null),
  ('l-alan', '00000000-0000-0000-0000-000000030001', current_date - 29, current_date - 31,
   'Alan', 'Disposition', 300, 'sec-form4', '0000300001-26-000030', 'nd:1'),
  ('l-edsger', '00000000-0000-0000-0000-000000030002', current_date - 30, current_date - 31,
   'Edsger', 'Acquisition', 50, 'sec-form4', '0000300002-26-000030', 'nd:1')
on conflict (trade_key) do nothing;

do $$
declare v_buys integer; v_sells integer; v_trades integer; v_net numeric; v_t2 integer;
begin
  select buys, sells, trades, net_shares into v_buys, v_sells, v_trades, v_net
    from market.security_insider_summary
   where security_id = '00000000-0000-0000-0000-000000030001';
  if v_trades is null then
    raise exception 'T1 has no summary row at all; the view dropped a security it should count';
  end if;
  if (v_buys, v_sells, v_trades) <> (2, 1, 3) then
    raise exception 'T1 counted % buys, % sells, % trades, expected 2, 1, 3: a trade two writers record must count once, an edge row on a day the lane has not collected must count, and a filing dated across a day boundary must not count twice',
      v_buys, v_sells, v_trades;
  end if;
  if v_net <> 0 then
    raise exception 'T1 net shares are %, expected 0 (100 + 200 bought, 300 sold)', v_net;
  end if;

  select trades into v_t2 from market.security_insider_summary
   where security_id = '00000000-0000-0000-0000-000000030002';
  if v_t2 is distinct from 1 then
    raise exception 'T2 counted % trades, expected its one lane row', v_t2;
  end if;
end $$;

\echo 'ok: a trade two writers record is counted once'

rollback;
