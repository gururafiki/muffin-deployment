-- SEC's segment parser reads bank and utility revenue totals as FALLBACKS, and the annual reports of
-- the companies with no split are read again (one-shot) (Phase 6c step 2, option A).
--
-- MEASURED 2026-11-26, over every held SEC annual filing of FY2023+ (muffin-ingest
-- `segments.segment_facts`, fallback rule):
--   - `RevenuesNetOfInterestExpense`, a bank's net revenue: Goldman Sachs (46.25 bn FY2023 by
--     business and by region), Nomura (1,562 bn yen), Community Financial;
--   - `RegulatedAndUnregulatedOperatingRevenue`, a utility's operating revenue: NextEra, DTE;
--   - `RevenueAndOperatingIncome`, IFRS total revenue and operating income: XP, and HSBC, whose
--     annual instances (35-55 MB) are read since the 64 MB gate (muffin-ingest#206).
-- As ORDINARY concepts they also changed 24 filings of 13 companies that already had a split
-- (Equinor FY2023 155.9 bn -> 106.8 bn), which is why they are fallbacks: a filing that places a
-- revenue split keeps exactly what it placed. `RevenueFromSaleOfGoods` was measured and left out:
-- it is an IFRS component of revenue, and it demoted Dr Reddy's, Buenaventura and Toyota.
--
-- THE RE-QUEUE TAKES SEC's ANNUAL ACCOUNTS FILINGS OF FY2023+ (report date in 2023 or later) OF
-- EQUITIES WITH NO PLACED ANNUAL REVENUE SPLIT (1,943 filings of 656 companies on 2026-11-26),
-- since a fallback only ever applies to a filing that places nothing. Nothing else was due (measured
-- rolled back), so that is under `sec_instances_due`'s 2,000 bound and the sensor drains it. Raw
-- holds ~78% of them; the rest are fetched again.
--
-- ORDER: after muffin-ingest#207 is rolled. Code before it reads these rows as ORDINARY concepts.

insert into market.segment_total_concept (regulator, metric_code, concept, priority, fallback, note) values
  ('sec', 'revenue', 'RevenuesNetOfInterestExpense', 60, true,
   'A bank''s net revenue: Goldman Sachs, Nomura, Community Financial (measured 2026-11-26).'),
  ('sec', 'revenue', 'RevenueAndOperatingIncome', 59, true,
   'IFRS total revenue and operating income: HSBC, XP (measured 2026-11-26).'),
  ('sec', 'revenue', 'RegulatedAndUnregulatedOperatingRevenue', 58, true,
   'A utility''s operating revenue: NextEra, DTE (measured 2026-11-26).')
on conflict (regulator, metric_code, concept) do update
   set priority = excluded.priority, fallback = excluded.fallback, note = excluded.note;

do $$
declare
  n int;
begin
  if exists (select 1 from market.one_shot where key = 'sec-fallback-totals-2026-11-26') then
    raise notice 'sec-fallback-totals: already applied';
    return;
  end if;

  update market.security_filing f
     set segments_parser_version = 0
    from market.security s
   where s.security_id = f.security_id
     and s.cik is not null
     and s.security_type_code = 'equity'
     and f.is_xbrl
     and f.report_date >= date '2023-01-01'
     and coalesce(f.segments_parser_version, 0) <> 0
     and f.report_type in (select form_code from market.filing_form
                            where source_code = 'sec' and is_annual and carries_segments)
     and not exists (
       select 1 from market.security_segment g
        where g.security_id = f.security_id
          and g.metric_code = 'revenue' and g.partition_id > 0 and g.parent_member is null
          and g.period_type = 'annual' and g.period_ending >= date '2023-01-01');
  get diagnostics n = row_count;

  insert into market.one_shot (key, reason)
  values ('sec-fallback-totals-2026-11-26',
          format('re-queued %s SEC annual reports of FY2023+ of equities with no placed revenue split', n));
end $$;
