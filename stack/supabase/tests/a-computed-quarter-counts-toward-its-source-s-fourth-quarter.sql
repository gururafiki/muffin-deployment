-- A COMPUTED QUARTER COUNTS TOWARD ITS SOURCE'S FOURTH QUARTER, AND NO OTHER SOURCE'S.
--
-- Security Y1: a SEC year of operating cash flow 1,000 (sec-xbrl), Q1 stated (100, sec-xbrl), Q2 and
-- Q3 computed from year-to-date facts (250 and 300, sec-xbrl-ytd). Right: a fourth quarter of 350
-- (derived-q4) and a TTM of 1,000 at the year end.
-- Security Y2: the same year and Q1, but its Q2 and Q3 are Yahoo's (yfinance): a provider's own
-- quarters do not complete another provider's year, so no fourth quarter and no TTM.
--
-- The candidate rules disagree:
--   - the year's source only (the old rule): Y1 has no fourth quarter, no TTM;
--   - any source: Y2 gains a fourth quarter of 350;
--   - computed_from read the wrong way round: Y1 has no fourth quarter.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.currency (code, name) values ('USD','US Dollar') on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZV','Ttmland','ZV',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000033001', 'Y1 Computed quarters', 'equity', 'ZV'),
  ('00000000-0000-0000-0000-000000033002', 'Y2 Another provider''s quarters', 'equity', 'ZV')
on conflict (security_id) do nothing;

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, currency_code, source_code) values
  ('00000000-0000-0000-0000-000000033001','operating_cash_flow','annual', date '2025-09-27', 1000,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000033001','operating_cash_flow','quarter',date '2024-12-28',  100,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000033001','operating_cash_flow','quarter',date '2025-03-29',  250,'USD','sec-xbrl-ytd'),
  ('00000000-0000-0000-0000-000000033001','operating_cash_flow','quarter',date '2025-06-28',  300,'USD','sec-xbrl-ytd'),
  ('00000000-0000-0000-0000-000000033002','operating_cash_flow','annual', date '2025-09-27', 1000,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000033002','operating_cash_flow','quarter',date '2024-12-28',  100,'USD','sec-xbrl'),
  ('00000000-0000-0000-0000-000000033002','operating_cash_flow','quarter',date '2025-03-29',  250,'USD','yfinance'),
  ('00000000-0000-0000-0000-000000033002','operating_cash_flow','quarter',date '2025-06-28',  300,'USD','yfinance');

do $$
declare v_q4 numeric; v_ttm numeric; v_y2 integer;
begin
  if (select computed_from from market.data_source where code = 'sec-xbrl-ytd') is distinct from 'sec-xbrl' then
    raise exception 'sec-xbrl-ytd does not name sec-xbrl as the source it is computed from';
  end if;

  perform market.derive_ttm('00000000-0000-0000-0000-000000033001');
  perform market.derive_ttm('00000000-0000-0000-0000-000000033002');

  select value into v_q4 from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000033001' and metric_code = 'operating_cash_flow'
     and period_type = 'quarter' and as_of = date '2025-09-27' and source_code = 'derived-q4';
  select value into v_ttm from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000033001' and metric_code = 'operating_cash_flow'
     and period_type = 'ttm' and as_of = date '2025-09-27';
  if (v_q4, v_ttm) is distinct from (350::numeric, 1000::numeric) then
    raise exception 'Y1 fourth quarter %, TTM %; expected 350 and 1,000: a quarter computed from the year''s own source must count toward its fourth quarter',
      coalesce(v_q4::text, '<none>'), coalesce(v_ttm::text, '<none>');
  end if;

  select count(*) into v_y2 from market.security_metric
   where security_id = '00000000-0000-0000-0000-000000033002' and metric_code = 'operating_cash_flow'
     and (source_code = 'derived-q4' or period_type = 'ttm');
  if v_y2 <> 0 then
    raise exception 'Y2 gained % fourth-quarter or TTM rows from another provider''s quarters', v_y2;
  end if;
end $$;

\echo 'ok: a computed quarter counts toward its source''s fourth quarter, and no other source''s'

rollback;
