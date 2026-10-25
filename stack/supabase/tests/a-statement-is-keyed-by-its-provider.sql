-- A statement is keyed by its provider: two providers keep their own row for one period, the
-- writers' conflict target is the provider key, and `FY` is no longer a period type.
-- Migration 20261025140000 (Phase 5 step 2b).
--
-- WHY. Under the old key (security, statement, period_ending, period_type) one provider's row for a
-- period excluded every other's: the Yahoo writer could only refuse to replace SEC's rows, and SEC's
-- company-facts statements would be refused wherever Yahoo held the date.
--
-- The fixture: one security whose FY2025 income statement is reported by `sec` and by yfinance, in
-- their own vocabularies and with different revenue. Each assertion fails under the old key:
--   1. both rows are stored                   (old key: the second insert violates the primary key)
--   2. the Yahoo writer's upsert, on the provider key, updates only yfinance's row and leaves `sec`'s
--                                             (old key: no constraint matches the conflict target)
--   3. a writer left on the OLD conflict target fails loudly rather than writing
--   4. the app reads one row for the period, `sec`'s, by priority (security_statement_current)
--   5. `FY` is refused, and the check is validated

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('yfinance','yfinance',100), ('sec','SEC EDGAR',250)
on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZK','Keyland','ZK',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009601', 'T96 Two Providers', 'equity', 'ZK');
insert into market.security_provider_symbol (security_id, provider_code, symbol)
values ('00000000-0000-0000-0000-000000009601', 'yfinance', 'TWOP');
refresh materialized view market.symbol_security;

insert into market.security_statement (security_id, statement, period_ending, period_type, currency,
                                       data, source_code, as_of) values
  ('00000000-0000-0000-0000-000000009601', 'income', date '2025-12-31', 'annual', 'USD',
   '{"revenue": 1000}'::jsonb, 'sec', now() - interval '2 days'),
  ('00000000-0000-0000-0000-000000009601', 'income', date '2025-12-31', 'annual', 'USD',
   '{"total_revenue": 990}'::jsonb, 'yfinance', now() - interval '1 day');

do $$
begin
  if (select count(*) from market.security_statement
       where security_id = '00000000-0000-0000-0000-000000009601') <> 2 then
    raise exception 'two providers'' statements for one period were not both kept';
  end if;
  raise notice 'ok  two providers keep their own row for one period';
end $$;

-- 2. The Yahoo writer's statement: the provider key, no guard on whose row it may replace.
insert into market.security_statement as st (security_id, statement, period_ending, period_type,
                                             currency, data, source_code, as_of)
values ('00000000-0000-0000-0000-000000009601', 'income', date '2025-12-31', 'annual', 'USD',
        '{"total_revenue": 995}'::jsonb, 'yfinance', now())
on conflict (security_id, source_code, statement, period_ending, period_type) do update
   set data = excluded.data, as_of = excluded.as_of
 where (st.data, st.as_of) is distinct from (excluded.data, excluded.as_of);

do $$
begin
  if (select data ->> 'total_revenue' from market.security_statement
       where security_id = '00000000-0000-0000-0000-000000009601' and source_code = 'yfinance')
     is distinct from '995' then
    raise exception 'the upsert on the provider key did not update yfinance''s row';
  end if;
  if (select data ->> 'revenue' from market.security_statement
       where security_id = '00000000-0000-0000-0000-000000009601' and source_code = 'sec')
     is distinct from '1000' then
    raise exception 'an upsert of yfinance''s row changed sec''s';
  end if;
  raise notice 'ok  the Yahoo writer''s upsert touches only its own row';
end $$;

-- 3. A writer left on the old conflict target must fail, not write.
do $$
begin
  begin
    insert into market.security_statement (security_id, statement, period_ending, period_type,
                                           currency, data, source_code)
    values ('00000000-0000-0000-0000-000000009601', 'income', date '2024-12-31', 'annual', 'USD',
            '{}'::jsonb, 'yfinance')
    on conflict (security_id, statement, period_ending, period_type) do nothing;
  exception when invalid_column_reference then
    raise notice 'ok  the old conflict target is refused: %', sqlerrm;
    return;
  end;
  raise exception 'an upsert on the old key (no provider) was accepted: the key still excludes '
                  'a second provider';
end $$;

-- 4. The app reads one row for the period, from the higher-priority provider.
do $$
declare n integer; src text;
begin
  select count(*), min(source_code) into n, src from market.security_statement_current
   where symbol = 'TWOP' and statement = 'income' and period_ending = date '2025-12-31';
  if (n, src) is distinct from (1, 'sec') then
    raise exception 'the period is served % time(s), from %; expected once, from sec', n, src;
  end if;
  raise notice 'ok  the period is served once, from sec';
end $$;

-- 5. `FY` is refused, and the check is enforced on every row, not only new ones.
do $$
begin
  if not (select convalidated from pg_constraint
           where conrelid = 'market.security_statement'::regclass
             and conname = 'security_statement_period_type_check') then
    raise exception 'the period-type check is not validated: stored rows were never checked';
  end if;
  begin
    insert into market.security_statement (security_id, statement, period_ending, period_type,
                                           currency, data, source_code)
    values ('00000000-0000-0000-0000-000000009601', 'balance', date '2025-12-31', 'FY', 'USD',
            '{}'::jsonb, 'sec');
  exception when check_violation then
    raise notice 'ok  FY is refused as a period type';
    return;
  end;
  raise exception 'a statement with period_type FY was accepted';
end $$;

rollback;
