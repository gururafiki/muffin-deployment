-- The repair of 2026-11-26 (migration 20261126200000) adds SEC's three fallback revenue totals and
-- re-queues the annual reports a fallback can change, and nothing else.
--
-- WHY THIS EXISTS AS A TEST: a one-shot over an empty database re-queues nothing, so applying the
-- migration set proves nothing about it. A fallback only applies to a filing that places no flat
-- revenue split, so the re-queue takes the annual accounts filings of FY2023+ of equities that hold
-- no placed, flat, annual revenue split of FY2023+. Each fixture row is kept in or out by one clause:
--   re-queued:
--     fb-none      a 10-K of FY2024; its company holds an unplaced revenue row and a placed
--                  operating-income split (partition and metric are load-bearing)
--     fb-nested    a 10-K of FY2024; its only placed revenue split is nested (a cross-tab cell)
--     fb-oldsplit  a 20-F of FY2024; its placed flat revenue splits are FY2021's (annual) and a
--                  FY2024 quarter's (period window and period type are load-bearing)
--   untouched:
--     fb-split     a 10-K of FY2024 of an equity holding a placed flat FY2024 split
--     fb-old       a 10-K of FY2022 (before the window)
--     fb-10q       a 10-Q of FY2024 (not the annual accounts)
--     fb-noxbrl    a 10-K of FY2024 carrying no XBRL
--     fb-amend     a 10-K/A of FY2024 (carries no segments)
--     fb-queued    a 10-K of FY2024 already behind the parser (not counted)
--     fb-fund      a 10-K of FY2024 of a security that is not an equity

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity'), ('fund','Fund')
  on conflict do nothing;
insert into market.data_source (code, name, priority) values
  ('sec-segments', 'SEC segments', 100), ('sec-submissions', 'SEC submissions', 100)
on conflict (code) do nothing;
insert into market.metric (code, name, category, unit, is_flow, is_derived, sort_order) values
  ('revenue', 'Revenue', 'income', 'currency', true, false, 1),
  ('operating_income', 'Operating income', 'income', 'currency', true, false, 2)
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, cik)
select ('00000000-0000-0000-0000-0000000262' || lpad(n::text, 2, '0'))::uuid, 'T262 ' || n,
       case when n = 10 then 'fund' else 'equity' end, 2620000 + n
  from generate_series(1, 10) n
on conflict (security_id) do nothing;

insert into market.security_filing
  (security_id, accession_number, filing_date, report_date, report_type, source_code, is_xbrl,
   segments_parsed_at, segments_parser_version)
select ('00000000-0000-0000-0000-0000000262' || n)::uuid, acc, filed, period, form,
       'sec-submissions', xbrl, case when version = 0 then null else timestamptz '2026-11-20' end,
       version
  from (values
    ('01', 'fb-none',     date '2025-02-01', date '2024-12-31', '10-K',   true,  20),
    ('02', 'fb-nested',   date '2025-02-01', date '2024-12-31', '10-K',   true,  20),
    ('03', 'fb-oldsplit', date '2025-04-01', date '2024-12-31', '20-F',   true,  20),
    ('04', 'fb-split',    date '2025-02-01', date '2024-12-31', '10-K',   true,  20),
    ('05', 'fb-old',      date '2023-02-01', date '2022-12-31', '10-K',   true,  20),
    ('06', 'fb-10q',      date '2024-08-01', date '2024-06-30', '10-Q',   true,  20),
    ('07', 'fb-noxbrl',   date '2025-02-01', date '2024-12-31', '10-K',   false, 20),
    ('08', 'fb-amend',    date '2025-03-01', date '2024-12-31', '10-K/A', true,  20),
    ('09', 'fb-queued',   date '2025-02-01', date '2024-12-31', '10-K',   true,  0),
    ('10', 'fb-fund',     date '2025-02-01', date '2024-12-31', '10-K',   true,  20)
  ) v (n, acc, filed, period, form, xbrl, version);

insert into market.security_segment
  (security_id, accession_number, axis, member_code, parent_axis, parent_member, metric_code,
   period_type, period_start, period_ending, value, source_code, partition_id, reconciled_to)
select ('00000000-0000-0000-0000-0000000262' || n)::uuid, acc, 'srt:ProductOrServiceAxis',
       member, p_axis, p_member, metric, ptype,
       (ending - case when ptype = 'quarter' then interval '3 months' else interval '1 year' end
               + interval '1 day')::date,
       ending, value, 'sec-segments', part, null
  from (values
    -- fb-none: a revenue row left unplaced, and a placed operating-income split
    ('01', 'fb-none', 't:AMember', null, null, 'revenue', 'annual', date '2024-12-31', 70, 0),
    ('01', 'fb-none', 't:AMember', null, null, 'operating_income', 'annual', date '2024-12-31', 7, 1),
    -- fb-nested: placed, but a cell under a parent member
    ('02', 'fb-nested', 't:AMember', 'us-gaap:StatementBusinessSegmentsAxis', 't:PMember',
     'revenue', 'annual', date '2024-12-31', 70, 1),
    -- fb-oldsplit: placed and flat, but FY2021, and a FY2024 quarter
    ('03', 'fb-oldsplit', 't:AMember', null, null, 'revenue', 'annual', date '2021-12-31', 70, 1),
    ('03', 'fb-oldsplit', 't:AMember', null, null, 'revenue', 'quarter', date '2024-06-30', 20, 1),
    -- fb-split: placed, flat, annual, FY2024
    ('04', 'fb-split', 't:AMember', null, null, 'revenue', 'annual', date '2024-12-31', 70, 1)
  ) v (n, acc, member, p_axis, p_member, metric, ptype, ending, value, part);

delete from market.one_shot where key = 'sec-fallback-totals-2026-11-26';
\i stack/supabase/migrations/20261126200000_sec_reads_bank_and_utility_revenue_as_a_fallback.sql

do $$
declare
  requeued text;
  expected constant text := 'fb-nested,fb-none,fb-oldsplit';
begin
  select string_agg(accession_number, ',' order by accession_number) into requeued
    from market.security_filing
   where accession_number like 'fb-%' and accession_number <> 'fb-queued'
     and segments_parser_version = 0;
  if requeued is distinct from expected then
    raise exception 're-queued % rather than %', coalesce(requeued, 'nothing'), expected;
  end if;
  if not exists (select 1 from market.one_shot where key = 'sec-fallback-totals-2026-11-26'
                    and reason like 're-queued 3 %') then
    raise exception 'the one-shot did not record the 3 it re-queued: %',
      (select reason from market.one_shot where key = 'sec-fallback-totals-2026-11-26');
  end if;
  if (select count(*) from market.segment_total_concept where regulator = 'sec' and fallback) <> 3
     or exists (select 1 from market.segment_total_concept where regulator = 'sec' and not fallback)
  then
    raise exception 'SEC''s added revenue totals must be exactly three fallbacks: %',
      (select string_agg(concept || '=' || fallback, ', ' order by concept)
         from market.segment_total_concept where regulator = 'sec');
  end if;
  if exists (select 1 from market.segment_total_concept where concept = 'RevenueFromSaleOfGoods') then
    raise exception 'RevenueFromSaleOfGoods is an IFRS component of revenue, measured to demote real splits';
  end if;
end $$;

rollback;
