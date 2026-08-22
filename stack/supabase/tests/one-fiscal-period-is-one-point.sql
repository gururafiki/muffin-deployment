-- One fiscal period must be one point, and the FILING's date must be the one shown.
--
-- WHY THIS EXISTS AS A TEST. The defect is a number that is merely present TWICE, with both copies
-- agreeing. No floor, no row count, no units check and no freshness rule can see it — only the
-- rendered chart, where AAPL's 2025 revenue appeared as two points three days apart.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. Four rules could be written here:
--
--   1. no collapse                     -> two points for 2025. The bug.
--   2. collapse, keep the LATEST date  -> keeps yfinance's rounded 09-30, drops the filing's 09-27
--   3. collapse, keep the EARLIEST     -> right here by luck, wrong whenever the filing is later
--   4. collapse, keep the HIGHEST-PRIORITY SOURCE -> what shipped
--
-- So the fixture gives the high-priority source the EARLIER date in one year and the LATER date in
-- the next. A fixture where the filing is always earlier cannot tell rule 3 from rule 4, and rule 3
-- would then survive a rewrite.
--
-- It also pins the boundary: 2023's two rows are 40 days apart and must stay SEPARATE, or the
-- collapse would start eating genuine periods.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('sec-xbrl','SEC XBRL company facts',275), ('yfinance','yfinance',100)
on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_derived, is_flow) values
  ('t126_revenue','T126 Revenue','income','currency',false,true)
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000126a01','T126 Filer','equity')
on conflict (security_id) do nothing;
insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000126a01','ticker','T126')
on conflict (kind_code, value) do nothing;

insert into market.security_metric
  (security_id, metric_code, period_type, as_of, value, source_code) values
  -- 2025: the FILING is EARLIER than the provider.
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2025-09-27', 416200000000,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2025-09-30', 416200000000,'yfinance'),
  -- 2024: the FILING is LATER than the provider. This pair is what separates "keep the earliest"
  -- from "keep the filing" — with both years the same way round, either rule passes.
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2024-09-26', 391000000000,'yfinance'),
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2024-09-29', 391000000000,'sec-xbrl'),
  -- 2023: FORTY DAYS apart. Two genuine periods; the collapse must not touch them.
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2023-08-20', 300000000000,'sec-xbrl'),
  ('00000000-0000-0000-0000-000000126a01','t126_revenue','annual','2023-09-29', 383300000000,'sec-xbrl')
on conflict do nothing;

do $$
declare
  n2025 integer; n2024 integer; n2023 integer;
  d2025 date;    d2024 date;
begin
  select count(*) into n2025 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2025-01-01' and '2025-12-31';
  if n2025 <> 1 then
    raise exception 'the 2025 fiscal year yields % rows, expected 1 — one fiscal year reported by '
                    'two sources is being plotted twice, with values that agree', n2025;
  end if;

  select as_of into d2025 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2025-01-01' and '2025-12-31';
  if d2025 <> date '2025-09-27' then
    raise exception '2025 survived as %, expected the filing date 2025-09-27 — the provider''s '
                    'rounded month end is being preferred over the true fiscal period end', d2025;
  end if;

  select count(*) into n2024 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2024-01-01' and '2024-12-31';
  if n2024 <> 1 then
    raise exception 'the 2024 fiscal year yields % rows, expected 1', n2024;
  end if;

  select as_of into d2024 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2024-01-01' and '2024-12-31';
  if d2024 <> date '2024-09-29' then
    raise exception '2024 survived as %, expected the filing date 2024-09-29 — the rule is keeping '
                    'the EARLIEST date rather than the highest-priority SOURCE, which is right only '
                    'when the filing happens to come first', d2024;
  end if;

  select count(*) into n2023 from market.security_metric_series
   where security_id = '00000000-0000-0000-0000-000000126a01'
     and metric_code = 't126_revenue' and as_of between '2023-01-01' and '2023-12-31';
  if n2023 <> 2 then
    raise exception 'two periods 40 days apart collapsed into % row(s) — the window has grown wide '
                    'enough to eat genuine periods', n2023;
  end if;

  raise notice 'ok  one fiscal period is one point, dated by the filing, and 40 days is still two';
end $$;

rollback;
