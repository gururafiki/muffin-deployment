-- A COMPANY THAT REPORTS IN HALVES IS NOT MISSING ITS QUARTERS.
--
-- WHY THIS IS A TEST. Yahoo labels a half-year `3M`, and the edge's `security-quarters` filed it as a
-- quarter: 3,094 such periods in 2,192 securities on 2026-10-10, 170-195 days apart. The Dagster
-- company lane files them as `period_type = 'half'` and retracts the edge's quarter row. If
-- `pending_quarters` still asked only for "no quarter row", the edge would re-queue that company and
-- write the halves back as quarters, and the two writers would undo each other on every visit.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZH','Halfland','ZH',false)
  on conflict (iso2) do nothing;

-- H reports in halves and holds them; Q (the control) holds only its annual statements.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000020201', 'T202 Halves', 'equity', 'ZH'),
  ('00000000-0000-0000-0000-000000020202', 'T202 Annual Only', 'equity', 'ZH')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T202H', '00000000-0000-0000-0000-000000020201', 'yfinance'),
  ('ticker', 'T202Q', '00000000-0000-0000-0000-000000020202', 'yfinance')
on conflict (kind_code, value) do nothing;
insert into market.security_statement (security_id, statement, period_ending, period_type, data, source_code) values
  ('00000000-0000-0000-0000-000000020201', 'income', date '2025-03-31', 'annual', '{}', 'yfinance'),
  ('00000000-0000-0000-0000-000000020201', 'income', date '2025-09-30', 'half',   '{}', 'yfinance'),
  ('00000000-0000-0000-0000-000000020201', 'income', date '2026-03-31', 'half',   '{}', 'yfinance'),
  ('00000000-0000-0000-0000-000000020202', 'income', date '2025-12-31', 'annual', '{}', 'yfinance')
on conflict do nothing;

do $$
declare n integer;
begin
  select count(*) into n from market.pending_quarters
   where security_id = '00000000-0000-0000-0000-000000020201';
  if n <> 0 then
    raise exception 'a company holding its half-years is queued for quarters (% rows) — the edge '
      'would write them back as quarters over the company lane''s halves', n;
  end if;
  select count(*) into n from market.pending_quarters
   where security_id = '00000000-0000-0000-0000-000000020202';
  if n <> 1 then
    raise exception 'a company with annual statements and no interim ones is not queued (% rows) — '
      'the half rule has emptied the backlog rather than scoped it', n;
  end if;
  raise notice '  ok  a semi-annual reporter is not missing its quarters, and the backlog still asks the rest';
end $$;

rollback;

\echo 'ok: a semi-annual reporter is not missing its quarters'
