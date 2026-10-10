-- THE DAGSTER WORKER CAN RUN BOTH DERIVATIONS, AS ITSELF.
--
-- WHY THIS IS A TEST. Every other test runs as a superuser, so a missing grant passes everything and
-- fails in production. Measured 2026-10-10: `ingest_rw` held EXECUTE on neither derive function, and
-- not on `source_priority`, which both call inside their upserts — so granting only the two would
-- still have failed, on the first conflict. This drives both as `ingest_rw`, end to end, over four
-- Yahoo quarters.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('derived','Computed',50) on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZD','Deriveland','ZD',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000020101', 'T201 Four Quarters', 'equity', 'ZD')
on conflict (security_id) do nothing;
insert into market.security_statement
  (security_id, statement, period_ending, period_type, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000020101','income',date '2025-03-31','quarter','USD','{"total_revenue": 10}','yfinance'),
  ('00000000-0000-0000-0000-000000020101','income',date '2025-06-30','quarter','USD','{"total_revenue": 20}','yfinance'),
  ('00000000-0000-0000-0000-000000020101','income',date '2025-09-30','quarter','USD','{"total_revenue": 30}','yfinance'),
  ('00000000-0000-0000-0000-000000020101','income',date '2025-12-31','quarter','USD','{"total_revenue": 40}','yfinance')
on conflict do nothing;

set local role ingest_rw;
select market.derive_security_metrics(100);
select market.derive_ttm('00000000-0000-0000-0000-000000020101', 100);
reset role;

do $$
declare n integer; v numeric;
begin
  select count(*) into n from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000020101'
     and metric_code = 'revenue' and period_type = 'quarter';
  if n <> 4 then
    raise exception 'ingest_rw derived % quarterly revenue metrics from four statements', n;
  end if;
  select value into v from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000020101'
     and metric_code = 'revenue' and period_type = 'ttm' and as_of = date '2025-12-31';
  if v is distinct from 100 then
    raise exception 'ingest_rw''s TTM is %, expected 100', coalesce(v::text, '<none>');
  end if;
  raise notice '  ok  ingest_rw derives metrics and TTM';
end $$;

rollback;

\echo 'ok: the worker can derive metrics and TTM as itself'
