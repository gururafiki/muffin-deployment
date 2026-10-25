-- AN INSIDER TRADE NAMES ITS FILING. Phase 5 step 2a of the umbrella's
-- docs/specs/2026-10-24-sec-family.md (decisions 4 and 10).
--
-- The edge keys a trade as `sha256(security|date|owner|direction|type|shares|price)`, with no
-- accession, so two identical lines in one filing collapse into one and an amended Form 4 cannot be
-- matched to the original. The SEC lane writes trades from SEC's own Insider Transactions Data Sets
-- (every quarter since 2006) and from each day's Form 4s, and keys them by the filing:
--   - `accession_number` and `line_key` (the table and ordinal of the line in the document, e.g.
--     'nd:3' for the third non-derivative line), unique per security where the accession is known;
--   - `issuer_cik`, `owner_cik`, `form_type`, `transaction_code`, `is_derivative`.
-- Legacy rows keep a null accession and are left alone; `security_insider_summary` switches to the
-- accession-bearing rows at the cutover (step 9), and the legacy rows go at the contract (step 11).
--
-- `market.insider_transaction_code` holds SEC's codes, transcribed from Form 4's General
-- Instruction 8 (SEC 1474 (03-26), OMB 3235-0287, https://www.sec.gov/files/form4.pdf, read
-- 2026-10-25): twenty codes in five groups. edgartools' own table was not used: it lacks K, L, V
-- and W, and describes I as "Disposition otherwise than to the issuer". V and K are modifiers on
-- the paper form ("S/K"); in the XML each line carries one code and separate flags.
--
-- NO FOREIGN KEY FROM `insider_trade.transaction_code`. A code the table lacks would fail the whole
-- insert, the shape of the TRL stall (2026-10-21: one unknown currency code stopped every metric
-- derivation for three days). The lane counts and withholds unknown codes instead.
--
-- Guard: stack/supabase/tests/an-insider-trade-names-its-filing.sql.

alter table market.insider_trade
  add column if not exists accession_number text,
  add column if not exists line_key text,
  add column if not exists issuer_cik integer,
  add column if not exists owner_cik integer,
  add column if not exists form_type text,
  add column if not exists transaction_code text,
  add column if not exists is_derivative boolean;

create unique index if not exists insider_trade_filing_line
  on market.insider_trade (security_id, accession_number, line_key)
  where accession_number is not null;

comment on column market.insider_trade.line_key is
  'Which line of the filing: nd:<n> for the n-th non-derivative transaction, d:<n> for the n-th '
  'derivative one, in document order. With accession_number, the line''s identity.';

create table if not exists market.insider_transaction_code (
  code       text primary key check (code ~ '^[A-Z]$'),
  name       text not null,
  code_group text not null
);
comment on table market.insider_transaction_code is
  'SEC''s Form 4 transaction codes, from General Instruction 8 of Form 4 (SEC 1474 (03-26)).';

insert into market.insider_transaction_code (code, name, code_group) values
  ('P', 'Open market or private purchase of non-derivative or derivative security', 'General'),
  ('S', 'Open market or private sale of non-derivative or derivative security', 'General'),
  ('V', 'Transaction voluntarily reported earlier than required', 'General'),
  ('A', 'Grant, award or other acquisition pursuant to Rule 16b-3(d)', 'Rule 16b-3'),
  ('D', 'Disposition to the issuer of issuer equity securities pursuant to Rule 16b-3(e)',
        'Rule 16b-3'),
  ('F', 'Payment of exercise price or tax liability by delivering or withholding securities '
        'incident to the receipt, exercise or vesting of a security issued in accordance with '
        'Rule 16b-3', 'Rule 16b-3'),
  ('I', 'Discretionary transaction in accordance with Rule 16b-3(f) resulting in acquisition or '
        'disposition of issuer securities', 'Rule 16b-3'),
  ('M', 'Exercise or conversion of derivative security exempted pursuant to Rule 16b-3',
        'Rule 16b-3'),
  ('C', 'Conversion of derivative security', 'Derivative securities'),
  ('E', 'Expiration of short derivative position', 'Derivative securities'),
  ('H', 'Expiration (or cancellation) of long derivative position with value received',
        'Derivative securities'),
  ('O', 'Exercise of out-of-the-money derivative security', 'Derivative securities'),
  ('X', 'Exercise of in-the-money or at-the-money derivative security', 'Derivative securities'),
  ('G', 'Bona fide gift', 'Other exempt and small acquisition'),
  ('L', 'Small acquisition under Rule 16a-6', 'Other exempt and small acquisition'),
  ('W', 'Acquisition or disposition by will or the laws of descent and distribution',
        'Other exempt and small acquisition'),
  ('Z', 'Deposit into or withdrawal from voting trust', 'Other exempt and small acquisition'),
  ('J', 'Other acquisition or disposition (describe transaction)', 'Other'),
  ('K', 'Transaction in equity swap or instrument with similar characteristics', 'Other'),
  ('U', 'Disposition pursuant to a tender of shares in a change of control transaction', 'Other')
on conflict (code) do nothing;

grant select on market.insider_transaction_code to anon, authenticated, ingest_rw;
grant select, insert, update, delete on market.insider_transaction_code to service_role;
-- The worker only reads it: `market`'s default privileges would otherwise give `ingest_rw` DML.
revoke insert, update, delete on market.insider_transaction_code from ingest_rw;
alter table market.insider_transaction_code enable row level security;
drop policy if exists insider_transaction_code_public_read on market.insider_transaction_code;
create policy insider_transaction_code_public_read on market.insider_transaction_code
  for select using (true);

insert into market.data_source (code, name, priority)
values ('sec-form345', 'SEC Insider Transactions Data Sets (Forms 3, 4 and 5)', 240)
on conflict (code) do nothing;
