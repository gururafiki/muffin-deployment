-- KOREA AND INDIA CARRY THE DEPTH-FIRST DEFECT MIGRATION 189 FIXED FOR SEC.
--
-- 189's finding: `round` is a `row_number()` computed in the SAME subquery as the "not yet parsed
-- at the current parser version" predicate. SQL applies `where` BEFORE window functions, so the
-- window sees only OUTSTANDING filings — and as a company drains, its remaining ones RENUMBER.
-- Parse its round 1 and the old round 2 becomes round 1 on the very next query, putting it straight
-- back at the head where `best_weight desc` hands it the page again. It is a moving target, not a
-- position in a round-robin.
--
-- `pending_kr_segments` (migration 172) and `pending_in_segments` (185) were both written from the
-- same template and both still have it. Reproduced against the SHIPPED views before writing this,
-- the same way 189 was: three companies, three annuals each, all parsed at an older version, then
-- three pages of ONE taken in a loop —
--
--     KOREA, three successive pages of one: SIMKR Heavy SIMKR Heavy SIMKR Heavy
--
-- Korea's backlog is **6,393** filings deep and about to start moving: PR #326 fixed the DART
-- `<status>014</status>` classification that had four filings holding its head through 143
-- identical runs. As soon as that head clears, this decides whether the next month reaches 3,516
-- Korean filers or a handful of large caps. India's is 523 and shallower only because it is new.
--
-- The fix is where the predicate SITS, not what it says: the window is computed over every ELIGIBLE
-- filing and the work predicate applied AFTER it, so `round` becomes the filing's stable depth into
-- its own company's history. Anything added to that inner `where` describing the STATE OF OUR WORK
-- rather than the nature of the row will reintroduce this.

-- ── Korea ───────────────────────────────────────────────────────────────────────────────────────
drop view if exists market.pending_kr_segments;
create view market.pending_kr_segments as
select security_id, accession_number, report_type, filing_date, filer_id, best_weight, round
from (
  select
    f.security_id, f.accession_number, f.report_type, f.filing_date, sf.filer_id,
    coalesce(max(h.weight), 0::numeric) as best_weight,
    (
      f.segments_parsed_at is null
      or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
    ) as needs_work,
    row_number() over (
      partition by f.security_id
      order by
        coalesce((select ff.is_annual from market.filing_form ff
                   where ff.source_code = 'dart' and ff.form_code = f.report_type limit 1), false) desc,
        f.filing_date desc,
        f.accession_number
    ) as round
  from market.security_filing f
  join market.security_filer sf on sf.security_id = f.security_id and sf.source_code = 'dart'
  left join market.fund_holding_current h on h.security_id = f.security_id
  where f.source_code = 'dart'
    and exists (
      select 1 from market.filing_form ff
       where ff.source_code = 'dart' and ff.form_code = f.report_type and ff.carries_segments
    )
  group by f.security_id, f.accession_number, f.report_type, f.filing_date, sf.filer_id,
           f.segments_parsed_at, f.segments_parser_version
) ranked
where needs_work
order by round, best_weight desc, accession_number;

comment on view market.pending_kr_segments is
  'Korean filings whose XBRL archive has not been read for segment facts. `round` is the filing''s STABLE depth into its own company''s history, computed over every eligible filing rather than only the outstanding ones — computing it over the outstanding set makes it renumber as the queue drains, which sends the heaviest company back to the head after every parse.';

-- A DROP TAKES THE GRANTS WITH IT, and superuser cannot see that (migration 189, same week).
grant select on market.pending_kr_segments to service_role;

-- ── India ───────────────────────────────────────────────────────────────────────────────────────
drop view if exists market.pending_in_segments;
create view market.pending_in_segments as
select security_id, accession_number, report_type, filing_date, filer_id, best_weight, round
from (
  select
    f.security_id, f.accession_number, f.report_type, f.filing_date, sf.filer_id,
    coalesce(max(h.weight), 0::numeric) as best_weight,
    (
      f.segments_parsed_at is null
      or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
    ) as needs_work,
    row_number() over (
      partition by f.security_id
      order by
        coalesce((select ff.is_annual from market.filing_form ff
                   where ff.source_code = 'nse' and ff.form_code = f.report_type limit 1), false) desc,
        f.filing_date desc,
        f.accession_number
    ) as round
  from market.security_filing f
  join market.security_filer sf on sf.security_id = f.security_id and sf.source_code = 'nse'
  left join market.fund_holding_current h on h.security_id = f.security_id
  where f.source_code = 'nse'
    and exists (
      select 1 from market.filing_form ff
       where ff.source_code = 'nse' and ff.form_code = f.report_type and ff.carries_segments
    )
  group by f.security_id, f.accession_number, f.report_type, f.filing_date, sf.filer_id,
           f.segments_parsed_at, f.segments_parser_version
) ranked
where needs_work
order by round, best_weight desc, accession_number;

comment on view market.pending_in_segments is
  'Indian filings whose XBRL instance has not been read for segment facts. `round` is the filing''s STABLE depth into its own company''s history — see pending_kr_segments for why computing it over the outstanding set instead makes the queue depth-first.';

grant select on market.pending_in_segments to service_role;

notify pgrst, 'reload schema';
