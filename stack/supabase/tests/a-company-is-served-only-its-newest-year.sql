-- A COMPANY IS SERVED ONLY ITS NEWEST YEAR (migration 20261127220000).
--
-- WHY. `security_segment_current` served every axis at its own newest period, so SF Holding's page
-- led with FY 2016 product and region splits above its 2025 operating segments. Within the
-- regulator a company is served from, only axes at the company's newest annual period are served.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE:
--   F  CNINFO: 分产品 newest 2016 (60 + 40), 经营分部 newest 2025 (700 + 300) -> only 经营分部
--   G  CNINFO: 分行业 and 分地区 both 2025, each with a 2024 comparative   -> both axes, 2025
--   H  SEC axes at 2024 and 2019, and a CNINFO axis at 2020                -> SEC's 2024 axis alone
--      (the regulator rule picks SEC; the year rule then drops SEC's 2019 axis, and judges by
--      SEC's newest, not by the CNINFO axis the regulator rule already dropped)
-- F also carries a cross-tab cell under its stale 2016 parent, and one under its 2025 parent:
-- `security_segment_detail` serves the second alone.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Periodia','ZW',false)
  on conflict (iso2) do nothing;
insert into market.currency (code) values ('USD'),('CNY') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000020112721','T2011 Changed Format Co','equity','ZW'),
  ('00000000-0000-0000-0000-000020112722','T2011 Two Axes Co','equity','ZW'),
  ('00000000-0000-0000-0000-000020112723','T2011 Two Regulators Co','equity','ZW')
on conflict do nothing;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code, accession_number, reconciled_to) values
  ('00000000-0000-0000-0000-000020112721','cninfo:分产品','cninfo:快递','revenue','annual',date '2016-12-31',60,'CNY',1,'cninfo','F-2016',100),
  ('00000000-0000-0000-0000-000020112721','cninfo:分产品','cninfo:仓储','revenue','annual',date '2016-12-31',40,'CNY',1,'cninfo','F-2016',100),
  ('00000000-0000-0000-0000-000020112721','cninfo:经营分部','cninfo:速运分部','revenue','annual',date '2025-12-31',700,'CNY',1,'cninfo','F-2025',1000),
  ('00000000-0000-0000-0000-000020112721','cninfo:经营分部','cninfo:供应链分部','revenue','annual',date '2025-12-31',300,'CNY',1,'cninfo','F-2025',1000),
  ('00000000-0000-0000-0000-000020112722','cninfo:分行业','cninfo:甲行业','revenue','annual',date '2025-12-31',80,'CNY',1,'cninfo','G-2025',100),
  ('00000000-0000-0000-0000-000020112722','cninfo:分行业','cninfo:乙行业','revenue','annual',date '2025-12-31',20,'CNY',1,'cninfo','G-2025',100),
  ('00000000-0000-0000-0000-000020112722','cninfo:分地区','cninfo:境内','revenue','annual',date '2025-12-31',90,'CNY',1,'cninfo','G-2025',100),
  ('00000000-0000-0000-0000-000020112722','cninfo:分地区','cninfo:境外','revenue','annual',date '2025-12-31',10,'CNY',1,'cninfo','G-2025',100),
  ('00000000-0000-0000-0000-000020112722','cninfo:分行业','cninfo:甲行业','revenue','annual',date '2024-12-31',75,'CNY',1,'cninfo','G-2025',95),
  ('00000000-0000-0000-0000-000020112722','cninfo:分行业','cninfo:乙行业','revenue','annual',date '2024-12-31',20,'CNY',1,'cninfo','G-2025',95),
  ('00000000-0000-0000-0000-000020112723','us-gaap:StatementBusinessSegmentsAxis','h:AMember','revenue','annual',date '2024-12-31',30,'USD',1,'sec-segments','H-SEC-2024',100),
  ('00000000-0000-0000-0000-000020112723','us-gaap:StatementBusinessSegmentsAxis','h:BMember','revenue','annual',date '2024-12-31',70,'USD',1,'sec-segments','H-SEC-2024',100),
  ('00000000-0000-0000-0000-000020112723','srt:StatementGeographicalAxis','h:USMember','revenue','annual',date '2019-12-31',40,'USD',1,'sec-segments','H-SEC-2019',100),
  ('00000000-0000-0000-0000-000020112723','srt:StatementGeographicalAxis','h:NonUSMember','revenue','annual',date '2019-12-31',60,'USD',1,'sec-segments','H-SEC-2019',100),
  ('00000000-0000-0000-0000-000020112723','cninfo:分行业','cninfo:H行业','revenue','annual',date '2020-12-31',90,'CNY',1,'cninfo','H-CN-2020',100),
  ('00000000-0000-0000-0000-000020112723','cninfo:分行业','cninfo:H其他','revenue','annual',date '2020-12-31',10,'CNY',1,'cninfo','H-CN-2020',100)
on conflict do nothing;

insert into market.security_segment
  (security_id, axis, member_code, metric_code, period_type, period_ending, value,
   currency_code, partition_id, source_code, accession_number, reconciled_to, parent_axis, parent_member) values
  ('00000000-0000-0000-0000-000020112721','cninfo:分地区','cninfo:华南','revenue','annual',date '2016-12-31',60,'CNY',1,'cninfo','F-2016',60,
   'cninfo:分产品','cninfo:快递'),
  ('00000000-0000-0000-0000-000020112721','cninfo:分地区','cninfo:华东','revenue','annual',date '2025-12-31',700,'CNY',1,'cninfo','F-2025',700,
   'cninfo:经营分部','cninfo:速运分部')
on conflict do nothing;

do $$
declare
  n    int;
  tot  numeric;
  axes text;
  ends text;
begin
  select count(*), sum(revenue), string_agg(distinct axis, ',' order by axis)
    into n, tot, axes
    from market.security_segment_current where security_id = '00000000-0000-0000-0000-000020112721';
  if n is distinct from 2 or tot is distinct from 1000 or axes is distinct from 'cninfo:经营分部' then
    raise exception 'F must be served its 2025 operating segments alone: got % rows summing % on axes % (4 / 1,100 / two axes = the stale 2016 split still served)', n, tot, axes;
  end if;

  select count(*), string_agg(distinct axis, ',' order by axis), string_agg(distinct period_ending::text, ',')
    into n, axes, ends
    from market.security_segment_current where security_id = '00000000-0000-0000-0000-000020112722';
  if n is distinct from 4 or axes is distinct from 'cninfo:分地区,cninfo:分行业' or ends is distinct from '2025-12-31' then
    raise exception 'G must keep both of its 2025 axes: got % rows on axes % at %', n, axes, ends;
  end if;

  select count(*), sum(revenue), string_agg(distinct axis, ',' order by axis)
    into n, tot, axes
    from market.security_segment_current where security_id = '00000000-0000-0000-0000-000020112723';
  if n is distinct from 2 or tot is distinct from 100 or axes is distinct from 'us-gaap:StatementBusinessSegmentsAxis' then
    raise exception 'H must be served SEC''s 2024 axis alone: got % rows summing % on axes %', n, tot, axes;
  end if;

  select count(*), string_agg(member_code, ',' order by member_code) into n, axes
    from market.security_segment_detail where security_id = '00000000-0000-0000-0000-000020112721';
  if n is distinct from 1 or axes is distinct from 'cninfo:华东' then
    raise exception 'F''s cross-tab must be served only under its 2025 parent: got % rows (%)', n, axes;
  end if;
end $$;

\echo ok: a company is served only its newest year, and a cross-tab only at a year current serves

rollback;
