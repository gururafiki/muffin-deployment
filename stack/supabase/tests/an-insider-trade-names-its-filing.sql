-- AN INSIDER TRADE NAMES ITS FILING, AND A LEGACY TRADE IS LEFT ALONE.
--
-- Migration 20261025100400 keys the SEC lane's insider trades by (security, accession, line):
--   1. two lines of one filing are two trades, even when every value matches (the edge's value
--      hash collapses them);
--   2. one line written twice is one trade, but the same line for a second security of the same
--      issuer (GOOG and GOOGL share a CIK, and Form 4 attribution names every equity of it) is a
--      second trade;
--   3. legacy rows, with no accession, are not constrained by it (54,109 of them in production);
--   4. an unknown transaction code is not refused by the table (no foreign key: the TRL lesson);
--   5. the code table holds SEC's twenty codes, and the worker cannot rewrite it.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('sec-form4','SEC Form 4',240)
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZI','Testinsideria','ZI',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009301', 'T93 Insider', 'equity', 'ZI'),
  ('00000000-0000-0000-0000-000000009302', 'T93 Insider Class C', 'equity', 'ZI')
on conflict (security_id) do nothing;

-- 1 and 4: two identical lines of one filing, one with a code the table does not hold.
insert into market.insider_trade
  (trade_key, security_id, transaction_date, owner_name, direction, shares, price, source_code,
   accession_number, line_key, transaction_code, is_derivative) values
  ('t93-1', '00000000-0000-0000-0000-000000009301', date '2026-09-01', 'A. Owner', 'Disposition',
   100, 10, 'sec-form4', '0000000000-26-000001', 'nd:1', 'S', false),
  ('t93-2', '00000000-0000-0000-0000-000000009301', date '2026-09-01', 'A. Owner', 'Disposition',
   100, 10, 'sec-form4', '0000000000-26-000001', 'nd:2', 'Q', false),
  ('t93-3', '00000000-0000-0000-0000-000000009302', date '2026-09-01', 'A. Owner', 'Disposition',
   100, 10, 'sec-form4', '0000000000-26-000001', 'nd:1', 'S', false);

-- 3: legacy rows with no accession, identical to each other but for the edge's own key.
insert into market.insider_trade
  (trade_key, security_id, transaction_date, owner_name, direction, shares, price, source_code) values
  ('t93-legacy-1', '00000000-0000-0000-0000-000000009301', date '2026-08-01', 'A. Owner', 'Acquisition', 5, 1, 'sec-form4'),
  ('t93-legacy-2', '00000000-0000-0000-0000-000000009301', date '2026-08-01', 'A. Owner', 'Acquisition', 5, 1, 'sec-form4');

do $$
declare n integer;
begin
  -- 2: the same line again must collide.
  begin
    insert into market.insider_trade
      (trade_key, security_id, transaction_date, direction, shares, source_code, accession_number, line_key)
    values ('t93-1-again', '00000000-0000-0000-0000-000000009301', date '2026-09-01', 'Disposition',
            100, 'sec-form4', '0000000000-26-000001', 'nd:1');
    raise exception 'one line of one filing was stored twice';
  exception when unique_violation then null;
  end;

  select count(*) into n from market.insider_trade
   where security_id = '00000000-0000-0000-0000-000000009301';
  if n <> 4 then
    raise exception 'expected two filing lines and two legacy rows, got % trades', n;
  end if;

  select count(*) into n from market.insider_transaction_code;
  if n <> 20 then
    raise exception 'SEC''s Form 4 lists twenty transaction codes, the table holds %', n;
  end if;
  if exists (select 1 from unnest(array['P','S','V','A','D','F','I','M','C','E','H','O','X','G','L',
                                         'W','Z','J','K','U']) c
              where not exists (select 1 from market.insider_transaction_code t where t.code = c)) then
    raise exception 'a Form 4 transaction code is missing from market.insider_transaction_code';
  end if;

  if has_table_privilege('ingest_rw', 'market.insider_transaction_code', 'INSERT')
     or has_table_privilege('ingest_rw', 'market.insider_transaction_code', 'UPDATE')
     or has_table_privilege('ingest_rw', 'market.insider_transaction_code', 'DELETE') then
    raise exception 'ingest_rw can rewrite market.insider_transaction_code';
  end if;
  if not has_table_privilege('ingest_rw', 'market.insider_transaction_code', 'SELECT') then
    raise exception 'ingest_rw cannot read market.insider_transaction_code';
  end if;

  if not exists (select 1 from market.data_source where code = 'sec-form345') then
    raise exception 'the sec-form345 data source is not seeded';
  end if;
end $$;

\echo ok an insider trade is keyed by its filing line, and legacy rows are left alone

rollback;
