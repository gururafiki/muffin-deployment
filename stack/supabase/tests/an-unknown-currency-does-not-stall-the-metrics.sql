-- AN UNKNOWN CURRENCY MUST NOT STALL THE METRICS, AND A CORRECTED ONE MUST REACH THEM.
--
-- From 2026-10-21 03:47 UTC every `derived_security_metrics` run failed on
-- `security_metric_currency_code_fkey ... (TRL)`: Yahoo labels some Turkish statements with the
-- lira code retired in 2005, `market.currency` has no such code, and the derivation pages by
-- `as_of`, so the page holding them failed and every page after it never ran. 161,001 statements
-- were underived by 10-24, and P/E and TTM froze for every company the lane had visited since.
--
-- The fixture puts the unknown code FIRST in the page and a known one after it. Under the old
-- function the whole call raises, so this file fails on its first statement. Four assertions:
--   1. the call completes and marks both statements derived;
--   2. the unknown code is WITHHELD (null), not copied, and the value still arrives;
--   3. a known code is KEPT (a mutation nulling every currency would pass 1 and 2);
--   4. correcting the stored currency re-queues the statement, and the new code reaches the metric.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.currency (code, name) values ('TRY','Turkish Lira') on conflict (code) do nothing;
delete from market.currency where code = 'TRL';
insert into market.countries (iso2, name, flag, drillable) values ('ZT','Testrkiye','ZT',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009101', 'T91 Unknown Currency', 'equity', 'ZT')
on conflict (security_id) do nothing;

-- The unknown code is older by `as_of`, so it is read first, exactly as Aksigorta's rows were.
insert into market.security_statement (security_id, statement, period_ending, period_type, currency, data, source_code, as_of) values
  ('00000000-0000-0000-0000-000000009101', 'income', date '2022-12-31', 'annual', 'TRL',
   '{"total_revenue": 7227436471}'::jsonb, 'yfinance', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-000000009101', 'income', date '2023-12-31', 'annual', 'USD',
   '{"total_revenue": 12629198332}'::jsonb, 'yfinance', now() - interval '1 hour');

select market.derive_security_metrics(null);

do $$
declare n integer; v numeric; c text;
begin
  select count(*) into n from market.security_statement
   where security_id = '00000000-0000-0000-0000-000000009101' and derived_at is null;
  if n <> 0 then
    raise exception 'an unknown currency stalled the derivation: % statement(s) left underived', n;
  end if;

  select value, currency_code into v, c from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009101' and metric_code = 'revenue'
     and period_type = 'annual' and as_of = date '2022-12-31';
  if v is distinct from 7227436471 then
    raise exception 'the statement with an unknown currency lost its value: revenue %', v;
  end if;
  if c is not null then
    raise exception 'an unknown currency was copied into the metric instead of withheld: %', c;
  end if;

  select currency_code into c from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009101' and metric_code = 'revenue'
     and period_type = 'annual' and as_of = date '2023-12-31';
  if c is distinct from 'USD' then
    raise exception 'a known currency was dropped from the metric: %', c;
  end if;
end $$;

-- The stage-2 correction: the row is relabelled TRY. It must re-queue and carry TRY through.
update market.security_statement set currency = 'TRY'
 where security_id = '00000000-0000-0000-0000-000000009101' and period_ending = date '2022-12-31';

do $$
declare n integer;
begin
  select count(*) into n from market.security_statement
   where security_id = '00000000-0000-0000-0000-000000009101' and period_ending = date '2022-12-31'
     and derived_at is null;
  if n <> 1 then
    raise exception 'a corrected currency did not re-queue the statement';
  end if;
end $$;

select market.derive_security_metrics(null);

do $$
declare c text;
begin
  select currency_code into c from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000009101' and metric_code = 'revenue'
     and period_type = 'annual' and as_of = date '2022-12-31';
  if c is distinct from 'TRY' then
    raise exception 'the corrected currency did not reach the metric: %', c;
  end if;
end $$;

\echo ok an unknown currency is withheld, a known one kept, and a corrected one re-derived

rollback;
