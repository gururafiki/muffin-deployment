-- AN INSIDER TRADE IS COUNTED FROM ITS FILING.
--
-- Until 2026-11-07 `insider_trade` had two writers: the edge `security-insider` resource (rows with
-- no accession) and the Dagster Form 4 lane (rows naming their filing). The summary kept an edge
-- row only for a filing day the lane had not collected. Phase 5 step 9 retired the edge writer, and
-- the lane's days cover the summary's whole 90-day window, so a row with no accession is a leftover
-- and is never counted. The legacy rows are deleted at the contract (step 11).
--
-- THE FIXTURE MAKES THE RULES DISAGREE about security T1, whose answer is 1 buy, 1 sell, 2 trades:
--   - count every row:                                3 buys, 2 sells, 5 trades;
--   - keep an edge row on a day the lane has not
--     collected (the view until 2026-11-07):          2 buys, 1 sell,  3 trades (Grace kept);
--   - count only rows that name their filing:         1 buy,  1 sell,  2 trades.

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
  if (v_buys, v_sells, v_trades) <> (1, 1, 2) then
    raise exception 'T1 counted % buys, % sells, % trades, expected 1, 1, 2: only a row naming its filing counts now the edge writer has retired',
      v_buys, v_sells, v_trades;
  end if;
  if v_net <> -200 then
    raise exception 'T1 net shares are %, expected -200 (100 bought, 300 sold)', v_net;
  end if;

  select trades into v_t2 from market.security_insider_summary
   where security_id = '00000000-0000-0000-0000-000000030002';
  if v_t2 is distinct from 1 then
    raise exception 'T2 counted % trades, expected its one lane row', v_t2;
  end if;
end $$;

\echo 'ok: an insider trade is counted from its filing'

rollback;
