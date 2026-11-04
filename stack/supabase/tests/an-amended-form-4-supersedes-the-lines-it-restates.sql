-- AN AMENDED FORM 4 SUPERSEDES THE LINES IT RESTATES, AND ONLY THOSE.
--
-- Security A1. Ada files a Form 4 for one day with three lines, then a 4/A restating only the
-- non-derivative purchase (100 -> 120 shares). Bea's 4/A is filed BEFORE her Form 4 for the same day,
-- so it amends an earlier filing. Cy trades the same day as Ada with the code Ada's 4/A restates.
-- Security A2 holds an Ada line for the same day with no amendment.
--
-- Right answer for A1: 3 buys (120, 500, 30), 3 sells (70, 40, 60), 6 trades, net 480,
-- buyers 2 (Ada, Cy), sellers 2 (Ada, Bea). Each candidate rule gives something else:
--   - count every row (the old view):               4 buys, 7 trades, net 580;
--   - skip on security, owner and day (the wording): 2 buys, 2 sells, 4 trades;
--   - drop the filing order:                        Bea's Form 4 skipped, 2 sells;
--   - drop the owner:                               Cy skipped, net 450;
--   - drop the derivative flag:                     Ada's grant skipped, net -20;
--   - drop the transaction code:                    Ada's sale skipped, 2 sells;
--   - drop the security:                            A2 loses its only line.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-form4','SEC Form 4',240)
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Insiderland','ZW',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000031001','A1 Amended','equity','ZW', 310001),
  ('00000000-0000-0000-0000-000000031002','A2 Same owner elsewhere','equity','ZW', 310001)
on conflict (security_id) do nothing;

insert into market.insider_trade
  (trade_key, security_id, filing_date, transaction_date, owner_name, owner_cik, direction, shares,
   source_code, accession_number, line_key, form_type, transaction_code, is_derivative, issuer_cik) values
  -- Ada's Form 4: three lines on one day. Only nd:1 is restated.
  ('ada-o-nd1', '00000000-0000-0000-0000-000000031001', current_date - 20, current_date - 21,
   'Ada', 1001, 'Acquisition', 100, 'sec-form4', '0000310001-26-000001', 'nd:1', '4', 'P', false, 310001),
  ('ada-o-nd2', '00000000-0000-0000-0000-000000031001', current_date - 20, current_date - 21,
   'Ada', 1001, 'Disposition', 70, 'sec-form4', '0000310001-26-000001', 'nd:2', '4', 'S', false, 310001),
  ('ada-o-d1', '00000000-0000-0000-0000-000000031001', current_date - 20, current_date - 21,
   'Ada', 1001, 'Acquisition', 500, 'sec-form4', '0000310001-26-000001', 'd:1', '4', 'P', true, 310001),
  -- Ada's 4/A, ten days later: the purchase, corrected.
  ('ada-a-nd1', '00000000-0000-0000-0000-000000031001', current_date - 10, current_date - 21,
   'Ada', 1001, 'Acquisition', 120, 'sec-form4', '0000310001-26-000002', 'nd:1', '4/A', 'P', false, 310001),
  -- Bea: the 4/A is filed before the Form 4 for the same day, so it amends something else.
  ('bea-a-nd1', '00000000-0000-0000-0000-000000031001', current_date - 30, current_date - 31,
   'Bea', 1002, 'Disposition', 40, 'sec-form4', '0000310001-26-000003', 'nd:1', '4/A', 'S', false, 310001),
  ('bea-o-nd1', '00000000-0000-0000-0000-000000031001', current_date - 25, current_date - 31,
   'Bea', 1002, 'Disposition', 60, 'sec-form4', '0000310001-26-000004', 'nd:1', '4', 'S', false, 310001),
  -- Cy: same security, day, flag and code as Ada's 4/A, another owner.
  ('cy-o-nd1', '00000000-0000-0000-0000-000000031001', current_date - 20, current_date - 21,
   'Cy', 1003, 'Acquisition', 30, 'sec-form4', '0000310001-26-000005', 'nd:1', '4', 'P', false, 310001),
  -- A2: Ada, same day, flag and code, another security, no amendment.
  ('ada-o-a2', '00000000-0000-0000-0000-000000031002', current_date - 20, current_date - 21,
   'Ada', 1001, 'Acquisition', 10, 'sec-form4', '0000310001-26-000001', 'nd:1', '4', 'P', false, 310001)
on conflict (trade_key) do nothing;

do $$
declare r record; v_a2 integer;
begin
  select buys, sells, trades, net_shares, buyers, sellers into r
    from market.security_insider_summary
   where security_id = '00000000-0000-0000-0000-000000031001';
  if r.trades is null then
    raise exception 'A1 has no summary row at all';
  end if;
  if (r.buys, r.sells, r.trades, r.net_shares, r.buyers, r.sellers) <> (3, 3, 6, 480, 2, 2) then
    raise exception 'A1 counted % buys, % sells, % trades, net %, % buyers, % sellers; expected 3, 3, 6, 480, 2, 2: an amendment supersedes only the original lines it restates (same owner, day, derivative flag and code, filed on or after)',
      r.buys, r.sells, r.trades, r.net_shares, r.buyers, r.sellers;
  end if;

  select trades into v_a2 from market.security_insider_summary
   where security_id = '00000000-0000-0000-0000-000000031002';
  if v_a2 is distinct from 1 then
    raise exception 'A2 counted % trades, expected 1: an amendment on another security superseded its line', v_a2;
  end if;
end $$;

\echo 'ok: an amended Form 4 supersedes the lines it restates, and only those'

rollback;
