-- THE CIK MAP MUST APPLY IN ONE STATEMENT, AND IT MUST BE IDEMPOTENT.
--
-- WHY THIS IS A TEST. The row-at-a-time version reached 6,645 of ~27,000 identifiers before its
-- deadline and restarted from zero every run — it could never reach the rest, while reporting
-- 3,516 matches as if that were progress. A number that looks like throughput and does not move is
-- the only symptom this class of bug has.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZT','Cikland','ZT',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009801', 'T98 Filer',       'equity', 'ZT'),
  ('00000000-0000-0000-0000-000000009802', 'T98 Other Class', 'equity', 'ZT'),
  ('00000000-0000-0000-0000-000000009803', 'T98 Not A Filer', 'equity', 'ZT')
on conflict (security_id) do nothing;
insert into market.identifier_kind (code, name) values ('isin','ISIN') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009804', 'T98 No Ticker', 'equity', 'ZT')
on conflict (security_id) do nothing;

insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T98A', '00000000-0000-0000-0000-000000009801', 'yfinance'),
  ('ticker', 'T98B', '00000000-0000-0000-0000-000000009802', 'yfinance'),
  ('ticker', 'T98Z', '00000000-0000-0000-0000-000000009803', 'yfinance'),
  -- A NON-TICKER identifier whose value collides with a key in the map. Without the kind filter
  -- the join matches it and hands this security a filer id belonging to someone else — and with
  -- every identifier in the fixture a ticker, the filtered and unfiltered joins give the same
  -- answer and a mutation deleting the filter passes clean.
  ('isin',   'T98A', '00000000-0000-0000-0000-000000009804', 'yfinance')
on conflict (kind_code, value) do nothing;

do $$
declare n integer; c integer;
begin
  -- 1. EVERY MATCHING SECURITY IS UPDATED BY ONE CALL — not the first N that fit in a deadline.
  --    Two share classes deliberately share a filer, which is why `security.cik` is not unique:
  --    GOOG and GOOGL are both CIK 1652044, and a unique index would make the second one fail.
  select market.apply_cik_map('{"T98A": 111, "T98B": 111, "NOTHELD": 999}'::jsonb) into n;
  if n <> 2 then
    raise exception 'one call updated % securities, expected 2 — a partial apply restarts from zero next run and never reaches the rest', n;
  end if;

  select cik into c from market.security where security_id = '00000000-0000-0000-0000-000000009801';
  if c is distinct from 111 then raise exception 'T98A did not get its cik (got %)', c; end if;
  select cik into c from market.security where security_id = '00000000-0000-0000-0000-000000009802';
  if c is distinct from 111 then raise exception 'the second share class of one filer was skipped (got %)', c; end if;

  -- 2. A TICKER SEC DOES NOT LIST GETS NOTHING, rather than a wrong filer.
  select cik into c from market.security where security_id = '00000000-0000-0000-0000-000000009803';
  if c is not null then raise exception 'a security absent from SEC''s list was given cik %', c; end if;

  -- 2b. AND AN IDENTIFIER OF THE WRONG KIND IS NOT A TICKER. SEC's map is keyed on ticker; an
  --     ISIN that happens to read like one belongs to a different security entirely.
  select cik into c from market.security where security_id = '00000000-0000-0000-0000-000000009804';
  if c is not null then
    raise exception 'a security matched on a NON-ticker identifier was given cik % — SEC''s map is keyed on ticker, so this is another company''s filer id', c;
  end if;

  -- 3. IDEMPOTENT. A second call must change NOTHING — otherwise a monthly resource rewrites every
  --    matched row for nothing, which is the WAL cost of a full table update.
  select market.apply_cik_map('{"T98A": 111, "T98B": 111}'::jsonb) into n;
  if n <> 0 then
    raise exception 'a repeat apply rewrote % rows — the statement must skip a security whose cik is already right', n;
  end if;

  -- 4. A CORRECTED CIK STILL LANDS. Idempotence must not mean "frozen at the first answer".
  select market.apply_cik_map('{"T98A": 222}'::jsonb) into n;
  if n <> 1 then raise exception 'a corrected cik did not apply (% rows)', n; end if;

  -- 5. A MALFORMED ENTRY DOES NOT ABORT THE STATEMENT. The function applies in one transaction,
  --    so one bad value would otherwise cost the whole map.
  select market.apply_cik_map('{"T98A": "not-a-number", "T98B": 333}'::jsonb) into n;
  if n <> 1 then
    raise exception 'a non-numeric entry took the batch with it (% rows updated, expected 1)', n;
  end if;
end $$;

rollback;

\echo 'ok: the cik map applies in one statement, skips non-filers, and is idempotent'
