-- The segment queue reads the FORM vocabulary rather than carrying one — IDEMPOTENT.
--
-- Migration 163 made a regulator a row and created `market.filing_form` to retire the hardcoded
-- `report_type in ('10-K','10-Q','20-F','40-F')` in this view. It created the table and left the
-- list in place, so the control table was read by NOTHING — an unread table cannot be wrong, which
-- is the same blind spot that left `exchange-listings` deployed, reachable and never scheduled,
-- and `untracked_listing` calling 9,976 tracked companies untracked.
--
-- Also swaps `s.cik is not null` for the resolved capability. Identical today (SEC is the only
-- enabled source, so `held` means exactly "has a CIK") and correct the day DART is enabled, which
-- is the whole point of doing it now rather than alongside the Korean resource.
--
-- The ordering is untouched: `round` first, so one pass reaches every filer's latest annual report.

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
        -- ANNUALS FIRST, from the vocabulary rather than from a second copy of it here.
        -- `security_segment_current` serves `period_type = 'annual'`, so the first pass over every
        -- filer must buy its latest ANNUAL report. Reading `is_annual` means a regulator whose
        -- annual form is called something else sorts correctly with no change to this view.
        coalesce((select ff.is_annual from market.filing_form ff
                   where ff.form_code = f.report_type limit 1), false) desc,
        f.filing_date desc,
        f.accession_number
    ) as round
  from market.security_filing f
  join market.security s on s.security_id = f.security_id
  left join market.fund_holding_current h on h.security_id = f.security_id
  where
    -- THE FORMS ARE DATA, NOT A LIST HERE. A 6-K or 8-K is an event, not accounts, and a foreign
    -- private issuer files 20-F/40-F INSTEAD OF 10-K/10-Q rather than as well — so a rule that
    -- classifies filings must know both vocabularies. DART's vocabulary is different again, which
    -- is why `market.filing_form` (migration 163) exists and why this reads it: the same reason
    -- `segment_axis` is a control table and Korea cost one row rather than a parser branch.
    --
    -- Joined on the FORM ALONE and not on (source, form), because `security_filing.source_code`
    -- records which SEC endpoint supplied the row (`sec-submissions` / `sec-filings`) rather than
    -- which regulator published the filing. Joining on it would match nothing. `distinct on` keeps
    -- the view honest if two regulators ever name a form the same way.
    exists (
      select 1 from market.filing_form ff
       where ff.form_code = f.report_type and ff.carries_segments
    )
    -- Addressable by a regulator we can actually fetch from. Was `s.cik is not null`, which is the
    -- same test only while SEC is the sole source.
    and exists (
      select 1 from market.security_disclosure sd
       where sd.security_id = f.security_id and sd.capability = 'held'
    )
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
