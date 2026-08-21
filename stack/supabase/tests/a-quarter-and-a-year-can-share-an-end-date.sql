-- A FISCAL-YEAR END IS BOTH AN ANNUAL PERIOD AND A FOURTH-QUARTER ONE.
--
-- `security_statement` was keyed `(security_id, statement, period_ending)`. SAP's 2025-12-31 arrives
-- twice with different numbers, and under that key the upsert silently REPLACES the annual figure
-- with three months of it — a revenue wrong by a factor of four, in the right units, with no error
-- anywhere. Nothing downstream could detect it: the row count is identical either way.
--
-- The second half of the file is the backlog. It must not offer a security that already has
-- quarters (it would pay three rate-limited calls to learn nothing), must not offer an SEC filer
-- (companyfacts already gives those seventeen years), and must not offer one with no annual
-- statements at all (the provider has never answered for that symbol, so it is a list of failures).

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Quarterland','ZW',false)
  on conflict (iso2) do nothing;

-- A: a foreign filer. No CIK, has annual statements — exactly what the backlog is for.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000010601','T106 Foreign','equity','ZW') on conflict do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','T106A','00000000-0000-0000-0000-000000010601','yfinance') on conflict do nothing;

-- B: an SEC filer. Has a CIK, so companyfacts covers it and yfinance must not be paid for 5 quarters.
insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000010602','T106 Filer','equity','ZW','0000000106') on conflict do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','T106B','00000000-0000-0000-0000-000000010602','yfinance') on conflict do nothing;

-- C: no annual statements at all — the provider has never answered for this symbol.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000010603','T106 Silent','equity','ZW') on conflict do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','T106C','00000000-0000-0000-0000-000000010603','yfinance') on conflict do nothing;

-- Annual statements for A and B. NOTE the same period_ending is used for the quarter below.
insert into market.security_statement
  (security_id, statement, period_ending, period_type, data, source_code, as_of) values
  ('00000000-0000-0000-0000-000000010601','income',date '2025-12-31','annual','{"total_revenue": 4000}','yfinance', now()),
  ('00000000-0000-0000-0000-000000010602','income',date '2025-12-31','annual','{"total_revenue": 4000}','yfinance', now())
on conflict do nothing;

do $$
declare n integer; v numeric;
begin
  -- ORDER MATTERS HERE: the backlog assertions run BEFORE the quarter is inserted, because
  -- inserting it is precisely what should REMOVE the security from the backlog (assertion 6).
  -- Checked the other way round, assertion 3 fails for the right reason and reads like a defect.

  -- 1. THE BACKLOG OFFERS THE FOREIGN FILER.
  select count(*) into n from market.pending_quarters where symbol = 'T106A';
  if n <> 1 then raise exception 'the foreign filer is not queued for quarters (% rows)', n; end if;

  -- 2. IT DOES NOT OFFER AN SEC FILER — companyfacts already gives it 17 years, so three
  --    rate-limited calls would buy a strictly worse answer.
  select count(*) into n from market.pending_quarters where symbol = 'T106B';
  if n <> 0 then raise exception 'an SEC filer is queued for yfinance quarters — that pays to overwrite the better record'; end if;

  -- 3. NOR ONE THE PROVIDER HAS NEVER ANSWERED FOR. Without this the backlog is a list of failures
  --    that never drains and crowds out the securities that would resolve.
  select count(*) into n from market.pending_quarters where symbol = 'T106C';
  if n <> 0 then raise exception 'a security with no annual statements is queued — nothing shows the provider answers for it'; end if;

  -- 4. THE TWO CAN COEXIST. Under the old key this insert REPLACED the annual row.
  insert into market.security_statement
    (security_id, statement, period_ending, period_type, data, source_code, as_of)
  values ('00000000-0000-0000-0000-000000010601','income',date '2025-12-31','quarter','{"total_revenue": 1000}','yfinance', now())
  on conflict (security_id, statement, period_ending, period_type) do update
    set data = excluded.data;

  select count(*) into n from market.security_statement
   where security_id = '00000000-0000-0000-0000-000000010601' and period_ending = date '2025-12-31';
  if n <> 2 then
    raise exception 'a fiscal-year end holds % row(s), expected 2 — the annual figure and the fourth quarter must coexist', n;
  end if;

  -- 5. AND THE ANNUAL FIGURE SURVIVED INTACT. This is the assertion that matters: a count of 2 with
  --    the year overwritten would still pass the check above.
  select (data->>'total_revenue')::numeric into v from market.security_statement
   where security_id = '00000000-0000-0000-0000-000000010601'
     and period_ending = date '2025-12-31' and period_type = 'annual';
  if v is distinct from 4000 then
    raise exception 'the ANNUAL revenue is now % — one quarter overwrote the year, which is a figure four times too small and in the right units', v;
  end if;

  -- 6. ONCE IT HAS QUARTERS IT LEAVES. The anti-join is over the SECURITY: a `where` clause filters
  --    ROWS, so the annual row would survive it and the security would be queued for ever — the
  --    defect that kept `pending_industry` re-fetching the same 300 securities for months.
  select count(*) into n from market.pending_quarters where symbol = 'T106A';
  if n <> 0 then
    raise exception 'the security still appears after gaining a quarter — a `where` filters rows, not securities';
  end if;

  -- 7. THE NEGATIVE CACHE IS CLEARED BY A NEW SYMBOL, via the shared function rather than a
  --    hand-written list at one call site.
  update market.security set quarters_missing_at = now()
   where security_id = '00000000-0000-0000-0000-000000010603';
  perform market.clear_symbol_caches('00000000-0000-0000-0000-000000010603');
  if (select quarters_missing_at from market.security
       where security_id = '00000000-0000-0000-0000-000000010603') is not null then
    raise exception 'a corrected symbol left quarters_missing_at set — the question was asked under the OLD spelling';
  end if;
end $$;

rollback;

\echo 'ok: a quarter and a year can share an end date, and the backlog is scoped'
