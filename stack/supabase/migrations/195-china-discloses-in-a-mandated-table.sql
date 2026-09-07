-- CHINA DISCLOSES ITS SEGMENTS IN A MANDATED TABLE, AND IT IS MACHINE-READABLE AFTER ALL.
--
-- Migration 183 recorded CNINFO as NOT VIABLE for segments because every filing is a PDF. That was
-- measured on the TRANSPORT and not on the DOCUMENTS. Measured on the documents 2026-09-06:
--
--   * the reports are TEXT PDFs, not scans;
--   * the CSRC MANDATES `主营业务分行业/分产品/分地区情况` in every A-share annual report, so this
--     is a standard form rather than per-company scraping;
--   * China Yangtze Power's industry split reconciles to 99.7% of consolidated revenue
--     (85,984,939,755.23 against 86,241,940,222 — the gap is 其他业务, which is precisely the
--     主营业务 / 营业收入 distinction, not an error);
--   * LONGi's five-member product split reconciles EXACTLY to its industry total
--     (129,497,674,192.20), and it discloses geography besides;
--   * extraction costs 166-168 ms and under 140 MB against a 90 s / 256 MB worker.
--
-- Worth 2,311 equities — the largest single coverage gap in the universe.
--
-- THREE AXES, ONE PER MANDATED TABLE. The axis string is the Chinese heading rather than a
-- translation, because it is what lands in `security_segment.axis` and a translated key would be
-- one more thing free to drift. `kind` matches the XBRL axes' vocabulary so the serving layer
-- treats these identically — `sector_constituents`, the donut and the stock page need no change.
insert into market.segment_axis (taxonomy, axis, kind, priority) values
  ('cninfo', 'cninfo:分行业', 'business',  90),
  ('cninfo', 'cninfo:分产品', 'product',  100),
  ('cninfo', 'cninfo:分地区', 'geography', 50)
on conflict (taxonomy, axis) do update
  set kind = excluded.kind, priority = excluded.priority;

-- ── the backlog ─────────────────────────────────────────────────────────────────────────────────
--
-- BREADTH-FIRST FROM THE START, with the work predicate applied AFTER the window — migrations 189
-- and 194 both had to retrofit that, and a third copy of the defect is not worth shipping to find
-- out. `round` is the filing's STABLE depth into its own company's history; computing it over the
-- outstanding set makes it renumber as the queue drains and hands the page back to the heaviest
-- company after every parse.
--
-- Only `年度报告` is eligible. Migration 193 gave the summary and the English edition their own
-- form codes with `carries_segments = false`, because neither contains the mandated table: the
-- summary omits it and the English edition uses English headings.
drop view if exists market.pending_cn_segments;
create view market.pending_cn_segments as
select security_id, accession_number, report_type, report_date, report_url, best_weight, round
from (
  select
    f.security_id, f.accession_number, f.report_type, f.report_date, f.report_url,
    coalesce(max(h.weight), 0::numeric) as best_weight,
    (
      f.segments_parsed_at is null
      or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
    ) as needs_work,
    row_number() over (
      partition by f.security_id
      order by f.report_date desc nulls last, f.accession_number
    ) as round
  from market.security_filing f
  left join market.fund_holding_current h on h.security_id = f.security_id
  where f.source_code = 'cninfo'
    and f.report_url is not null
    and exists (
      select 1 from market.filing_form ff
       where ff.source_code = 'cninfo' and ff.form_code = f.report_type and ff.carries_segments
    )
  group by f.security_id, f.accession_number, f.report_type, f.report_date, f.report_url,
           f.segments_parsed_at, f.segments_parser_version
) ranked
where needs_work
order by round, best_weight desc, accession_number;

comment on view market.pending_cn_segments is
  'Chinese annual reports whose PDF has not been read for segment facts. Only `年度报告` is eligible — the summary and the English edition have their own form codes and carry no segment table. `round` is the filing''s STABLE depth into its own company''s history, computed over every eligible filing rather than only the outstanding ones.';

-- A DROP TAKES THE GRANTS WITH IT, and superuser cannot see that (migration 189, same week).
grant select on market.pending_cn_segments to service_role;

-- ── schedule it ─────────────────────────────────────────────────────────────────────────────────
-- A RESOURCE THAT IS NEVER INVOKED CANNOT FAIL — `exchange-listings` was deployed, reachable and
-- absent from the cron for weeks. The `(position, resource)` form is the one logic-check's
-- scheduling guard parses; a second spelling reads as scheduled while the guard reports it absent.
insert into market.cron_resource (position, resource) values
  (450, 'security-cn-segments')
on conflict (position) do update set resource = excluded.resource;

-- ── turn it on ──────────────────────────────────────────────────────────────────────────────────
--
-- DELIBERATELY LAST, and deliberately in this migration rather than an earlier one: until the
-- parser and the resource exist, `carries_segments = true` would advertise work nothing can do and
-- `capability = 'resolvable'` would be a promise. `disclosure_source.enabled` is what moves 2,311
-- Chinese equities off `none`.
update market.filing_form set carries_segments = true
 where source_code = 'cninfo' and form_code = '年度报告';

insert into market.disclosure_coverage (source_code, country_iso2) values ('cninfo', 'CN')
on conflict (source_code, country_iso2) do nothing;

update market.disclosure_source set enabled = true where code = 'cninfo';

notify pgrst, 'reload schema';
