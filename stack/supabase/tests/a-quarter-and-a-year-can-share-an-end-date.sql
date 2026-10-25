-- A FISCAL-YEAR END IS BOTH AN ANNUAL PERIOD AND A FOURTH-QUARTER ONE.
--
-- `security_statement` was keyed `(security_id, statement, period_ending)`. SAP's 2025-12-31 arrives
-- twice with different numbers, and under that key the upsert silently REPLACES the annual figure
-- with three months of it — a revenue wrong by a factor of four, in the right units, with no error
-- anywhere. Nothing downstream could detect it: the row count is identical either way.
--
-- The backlog half of this file (`pending_quarters`) left with the edge handler on 2026-10-24.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Quarterland','ZW',false)
  on conflict (iso2) do nothing;

-- A: a security holding an annual statement.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000010601','T106 Foreign','equity','ZW') on conflict do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','T106A','00000000-0000-0000-0000-000000010601','yfinance') on conflict do nothing;

-- C: a security whose negative cache a corrected symbol must clear.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000010603','T106 Silent','equity','ZW') on conflict do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','T106C','00000000-0000-0000-0000-000000010603','yfinance') on conflict do nothing;

-- An annual statement for A. NOTE the same period_ending is used for the quarter below.
insert into market.security_statement
  (security_id, statement, period_ending, period_type, data, source_code, as_of) values
  ('00000000-0000-0000-0000-000000010601','income',date '2025-12-31','annual','{"total_revenue": 4000}','yfinance', now())
on conflict do nothing;

do $$
declare n integer; v numeric;
begin
  -- 1. THE TWO CAN COEXIST. Under the old key this insert REPLACED the annual row. (The conflict
  --    target names the provider since migration 20261025140000, as the Yahoo writer's does.)
  insert into market.security_statement
    (security_id, statement, period_ending, period_type, data, source_code, as_of)
  values ('00000000-0000-0000-0000-000000010601','income',date '2025-12-31','quarter','{"total_revenue": 1000}','yfinance', now())
  on conflict (security_id, source_code, statement, period_ending, period_type) do update
    set data = excluded.data;

  select count(*) into n from market.security_statement
   where security_id = '00000000-0000-0000-0000-000000010601' and period_ending = date '2025-12-31';
  if n <> 2 then
    raise exception 'a fiscal-year end holds % row(s), expected 2 — the annual figure and the fourth quarter must coexist', n;
  end if;

  -- 2. AND THE ANNUAL FIGURE SURVIVED INTACT. This is the assertion that matters: a count of 2 with
  --    the year overwritten would still pass the check above.
  select (data->>'total_revenue')::numeric into v from market.security_statement
   where security_id = '00000000-0000-0000-0000-000000010601'
     and period_ending = date '2025-12-31' and period_type = 'annual';
  if v is distinct from 4000 then
    raise exception 'the ANNUAL revenue is now % — one quarter overwrote the year, which is a figure four times too small and in the right units', v;
  end if;

  -- 3. THE NEGATIVE CACHE IS CLEARED BY A NEW SYMBOL, via the shared function rather than a
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
