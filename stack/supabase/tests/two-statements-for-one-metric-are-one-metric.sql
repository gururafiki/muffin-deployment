-- TWO STATEMENTS FOR ONE METRIC IN ONE PAGE ARE ONE METRIC, FROM THE BETTER SOURCE.
--
-- Found 2026-10-25 by re-deriving AAPL, MSFT and 7203.T in a rolled-back transaction on production:
-- the derivation then in production failed the whole page with `ON CONFLICT DO UPDATE command
-- cannot affect row a second time`. AAPL's FY2023 balance sheet is held twice, as `FY` from `sec`
-- and `annual` from yfinance, and both map to the `annual` metric for 2023-09-30. Their short-term
-- debt even disagrees (5,985,000,000 against 15,807,000,000). 4,694 metric keys across 57
-- securities are held twice this way. It stays latent while the twins are never underived
-- together, and the label pass re-queues a security's statements all at once.
--
-- The fixture puts both twins in one page, with different values, plus a pair of EQUAL priority
-- where the newer statement must win. It fails on the old function with the error above.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('yfinance','yfinance',100), ('sec','SEC EDGAR',250), ('fmp','FMP',90), ('finviz','finviz',90)
on conflict (code) do nothing;
insert into market.metric_source_field (metric_code, source_code, statement, field) values
  ('short_term_debt', 'fmp', 'balance', 'short_term_debt'),
  ('short_term_debt', 'finviz', 'balance', 'short_term_debt')
on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Testwinland','ZW',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009501', 'T95 Held Twice', 'equity', 'ZW')
on conflict (security_id) do nothing;

do $$
begin
  if not exists (select 1 from market.metric_source_field
                  where metric_code = 'short_term_debt' and source_code = 'sec' and statement = 'balance')
     or not exists (select 1 from market.metric_source_field
                  where metric_code = 'short_term_debt' and source_code = 'yfinance' and statement = 'balance')
     or (select count(*) from market.metric_source_field
          where metric_code = 'short_term_debt' and source_code in ('fmp', 'finviz') and statement = 'balance') <> 2 then
    raise exception 'the fixture needs sec, yfinance, fmp and finviz balance-sheet spellings of short_term_debt';
  end if;
end $$;

insert into market.security_statement (security_id, statement, period_ending, period_type, currency, data, source_code, as_of)
select '00000000-0000-0000-0000-000000009501', 'balance', date '2023-09-30', p.period_type, 'USD',
       jsonb_build_object(f.field, p.value), p.source_code, now() - p.age
  from (values ('FY', 'sec', 5985000000::numeric, interval '2 hours'),
               ('annual', 'yfinance', 15807000000::numeric, interval '1 hour'),
               ('quarter', 'fmp', 1::numeric, interval '2 hours')) p (period_type, source_code, value, age)
  join market.metric_source_field f
    on f.metric_code = 'short_term_debt' and f.source_code = p.source_code and f.statement = 'balance';
-- The equal-priority pair: same metric key (quarter, 2023-09-30), finviz newer than fmp.
insert into market.security_statement (security_id, statement, period_ending, period_type, currency, data, source_code, as_of)
select '00000000-0000-0000-0000-000000009501', 'balance', date '2023-09-30', 'Q4', 'USD',
       jsonb_build_object(f.field, 2), 'finviz', now() - interval '1 hour'
  from market.metric_source_field f
 where f.metric_code = 'short_term_debt' and f.source_code = 'finviz' and f.statement = 'balance';

select market.derive_security_metrics(null);

do $$
declare v numeric; src text; n integer;
begin
  select value, source_code into v, src from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009501' and metric_code = 'short_term_debt'
     and period_type = 'annual' and as_of = date '2023-09-30';
  if (v, src) is distinct from (5985000000::numeric, 'sec') then
    raise exception 'two statements for one metric must give the higher-priority source''s value: got % from %', v, src;
  end if;

  select value, source_code into v, src from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009501' and metric_code = 'short_term_debt'
     and period_type = 'quarter' and as_of = date '2023-09-30';
  if (v, src) is distinct from (2::numeric, 'finviz') then
    raise exception 'between equal priorities the newer statement must win: got % from %', v, src;
  end if;

  select count(*) into n from market.security_statement
   where security_id = '00000000-0000-0000-0000-000000009501' and derived_at is null;
  if n <> 0 then
    raise exception '% statement(s) left underived: the twin that lost must still be marked', n;
  end if;
end $$;

\echo ok two statements for one metric in one page give one metric, from the better source

rollback;
