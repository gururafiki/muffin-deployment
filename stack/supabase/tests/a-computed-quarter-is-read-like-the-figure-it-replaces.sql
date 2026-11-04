-- A COMPUTED QUARTER IS READ LIKE THE FIGURE IT REPLACES, AND RANKS BELOW A STATED ONE.
--
-- muffin-ingest computes a SEC filer's Q2 and Q3 from year-to-date facts and writes them under
-- `sec-xbrl-ytd` (migration 20261104130000). Two rules make that safe:
--   1. THE MAPPINGS ARE THE SAME. The derivation joins `metric_source_field` on the row's source,
--      so the computed rows need `sec-xbrl`'s income and cash mappings, held equal here. A line
--      added to `sec-xbrl` alone would be silently absent from every computed quarter.
--   2. A STATED FIGURE WINS. At the metric level a stated line (`sec-xbrl` 275, `yfinance` 100)
--      outranks a computed one (45), which fills only what nothing states.
--
-- THE FIXTURE MAKES THE PRIORITIES DISAGREE, for security C1:
--   - 2025-06-28: SEC states depreciation 30 and computes 31 beside its computed cash flow 150.
--     Right: depreciation 30 (sec-xbrl), operating cash flow 150 (computed).
--     Computed ranked above sec-xbrl: depreciation 31.
--   - 2025-09-27: Yahoo states operating cash flow 175, SEC computes 170.
--     Right: 175 (yfinance). Computed ranked above yfinance: 170.
--   - No mapping for the computed source: no operating cash flow at 2025-06-28 at all.

\set ON_ERROR_STOP on

begin;

do $$
declare v_missing text; v_extra text;
begin
  select string_agg(f.metric_code, ', ' order by f.metric_code) into v_missing
    from market.metric_source_field f
   where f.source_code = 'sec-xbrl' and f.statement in ('income', 'cash')
     and not exists (select 1 from market.metric_source_field y
                      where y.source_code = 'sec-xbrl-ytd' and y.metric_code = f.metric_code
                        and y.statement = f.statement and y.field = f.field);
  select string_agg(y.metric_code, ', ' order by y.metric_code) into v_extra
    from market.metric_source_field y
   where y.source_code = 'sec-xbrl-ytd'
     and not exists (select 1 from market.metric_source_field f
                      where f.source_code = 'sec-xbrl' and f.metric_code = y.metric_code
                        and f.statement = y.statement and f.field = y.field
                        and f.statement in ('income', 'cash'));
  if v_missing is not null then
    raise exception 'sec-xbrl maps % for income or cash and sec-xbrl-ytd does not: a computed quarter would never carry it', v_missing;
  end if;
  if v_extra is not null then
    raise exception 'sec-xbrl-ytd maps % with no sec-xbrl income or cash twin', v_extra;
  end if;
  if (select count(*) from market.metric_source_field where source_code = 'sec-xbrl-ytd') < 6 then
    raise exception 'sec-xbrl-ytd has fewer mappings than sec-xbrl has cash lines: the copy did not run';
  end if;
end $$;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZM','Testland','ZM',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000032001', 'C1 Computed quarters', 'equity', 'ZM')
on conflict (security_id) do nothing;

insert into market.security_statement
  (security_id, statement, period_ending, period_type, currency, data, source_code) values
  ('00000000-0000-0000-0000-000000032001', 'cash', date '2025-06-28', 'quarter', 'USD',
   '{"depreciation": 30}'::jsonb, 'sec-xbrl'),
  ('00000000-0000-0000-0000-000000032001', 'cash', date '2025-06-28', 'quarter', 'USD',
   '{"operating_cash_flow": 150, "depreciation": 31}'::jsonb, 'sec-xbrl-ytd'),
  ('00000000-0000-0000-0000-000000032001', 'cash', date '2025-09-27', 'quarter', 'USD',
   '{"operating_cash_flow": 170}'::jsonb, 'sec-xbrl-ytd'),
  ('00000000-0000-0000-0000-000000032001', 'cash', date '2025-09-27', 'quarter', 'USD',
   '{"operating_cash_flow": 175}'::jsonb, 'yfinance');

select market.derive_security_metrics(null);

do $$
declare r record; v_got text;
begin
  select string_agg(format('%s %s %s %s', metric_code, as_of, value, source_code), '; '
                    order by metric_code, as_of) into v_got
    from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000032001' and period_type = 'quarter'
     and metric_code in ('operating_cash_flow', 'depreciation');
  if v_got is distinct from
     'depreciation 2025-06-28 30 sec-xbrl; operating_cash_flow 2025-06-28 150 sec-xbrl-ytd; operating_cash_flow 2025-09-27 175 yfinance'
  then
    raise exception 'derived %; expected depreciation 30 from sec-xbrl, operating cash flow 150 computed, and 175 from yfinance: a stated figure must outrank a computed quarter, and a computed one must be read', v_got;
  end if;
end $$;

\echo 'ok: a computed quarter is read like the figure it replaces, and ranks below a stated one'

rollback;
