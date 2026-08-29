-- Order the segment backlog BREADTH-FIRST — IDEMPOTENT.
--
-- MEASURED IN PRODUCTION 2026-08-29, and it is the reason the feature this table exists for does
-- not work yet. `pending_segments` shipped `order by best_weight desc, accession_number`. Fund
-- weight is a property of the SECURITY, so every one of a company's filings carries the same key
-- and the accession tiebreak then runs through that company's entire history before the next
-- company is touched. 440 filings had been parsed and they belong to **14 securities**:
--
--     filings per security: 69, 69, 69, 65, 61, 57, 39, 15, 10, 9, 9, 9, 8, 5
--
-- So the pipeline had spent a day parsing Amazon's 1998 10-Q while Microsoft, Alphabet and Meta
-- had no segment row at all. Nothing could report this: `written` read as throughput (240-450 rows
-- a run), `remaining` fell, `ok` was true every time, and the reconciliation guard passed — because
-- the data being written was CORRECT. It was the wrong data first.
--
-- It matters because the point of this table is CROSS-COMPANY comparison. One company's twenty-year
-- history is worth less than twenty companies' latest year: with a depth-first queue exactly one
-- concept (`digital-advertising`) had two companies on it, and `cloud-infrastructure` had one — so
-- "compare AWS to Google Cloud" was blocked on an ordering, not on a vocabulary or a provider.
--
-- Reproduced offline before changing anything, at ~7x the current backlog (3,500 filers x 70
-- filings = 245,000 rows): a page of 20 returned twenty filings of `0000000001`. Under the
-- ordering below the same page returns twenty DIFFERENT companies, each its most recent 10-K.
--
-- THE ROUND IS COMPUTED OVER PENDING FILINGS ONLY, so it self-rebalances: a filing that is parsed
-- leaves, and that company's next filing becomes its round 1. A filing SEC could not serve an
-- instance for is stamped `segments_parsed_at` too (the resource stamps whether or not facts were
-- found — only a THROW re-queues), so a company cannot wedge the queue on its own head.
--
-- ANNUALS BEFORE QUARTERLIES, deliberately. `security_segment_current` serves `period_type =
-- 'annual'`, and a 10-K carries the audited segment note a 10-Q abbreviates — so the first pass
-- over 3,500 filers buys every filer's latest ANNUAL segmentation, which is the unit the
-- comparison is drawn in. Quarterly depth follows once the annual rounds are exhausted.
--
-- Cost, measured at 245,000 rows on postgres:17 — page 489 ms, count 857 ms, against the PostgREST
-- role's 8-second statement timeout. (The previous ordering was 323 ms / 467 ms; the window
-- function is worth 166 ms.) This is a service-role backlog, so anon's 3-second ceiling does not
-- apply, but it is measured rather than assumed because a view whose plan changed under a filter
-- has broken the chart here twice.

drop view if exists market.pending_segments;
create view market.pending_segments as
select
  security_id,
  accession_number,
  report_type,
  filing_date,
  filing_detail_url,
  cik,
  best_weight,
  round
from (
  select
    f.security_id,
    f.accession_number,
    f.report_type,
    f.filing_date,
    f.filing_detail_url,
    s.cik,
    coalesce(max(h.weight), 0) as best_weight,
    -- How deep into THIS company's history the filing sits. Round 1 is every filer's most recent
    -- annual report; the outer `order by round` is what turns a depth-first walk into a
    -- breadth-first one without changing which filings are eligible.
    row_number() over (
      partition by f.security_id
      order by
        (f.report_type in ('10-K', '20-F', '40-F')) desc,
        f.filing_date desc,
        f.accession_number
    ) as round
  from market.security_filing f
  join market.security s on s.security_id = f.security_id
  left join market.fund_holding_current h on h.security_id = f.security_id
  where
    -- The forms that carry audited segment disclosure. A 6-K or 8-K is an event, not accounts, and
    -- a foreign private issuer files 20-F/40-F INSTEAD OF 10-K/10-Q rather than as well.
    f.report_type in ('10-K', '10-Q', '20-F', '40-F')
    and s.cik is not null
    -- An ANTI-JOIN over the work grain, never an `order by ... limit`. `derive_security_metrics`
    -- shipped the latter and returned the same page for ever while `written` read as throughput.
    -- Unchanged by this migration: only the ORDER of a shrinking set moved.
    and (
      f.segments_parsed_at is null
      or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
    )
  group by f.security_id, f.accession_number, f.report_type, f.filing_date, f.filing_detail_url, s.cik
) ranked
-- Round first so breadth beats depth; weight second so within a round the companies people are
-- actually holding are parsed first; the accession as a UNIQUE tiebreak, because a paged read over
-- a non-total ordering is how a backlog re-reads its own head.
order by round, best_weight desc, accession_number;

comment on view market.pending_segments is
  'Filings whose XBRL instance has not been read for segment facts. Ordered BREADTH-FIRST: `round` is the filing''s depth into its own company''s history (annuals before quarterlies), so one pass covers every filer''s latest annual report before any company''s second filing is touched. Ordering by fund weight alone parsed 14 companies out of 3,500.';

grant select on market.pending_segments to service_role;

notify pgrst, 'reload schema';
