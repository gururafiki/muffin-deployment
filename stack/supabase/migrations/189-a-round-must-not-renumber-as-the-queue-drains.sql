-- BREADTH-FIRST HELD FOR ONE PAGE AND THEN STOPPED, AND EVERY COUNTER SAID HEALTHY.
--
-- Migration 156 fixed a depth-first `pending_segments` by adding `round` — the filing's depth into
-- its own company's history — so that one pass covers every filer's latest annual before any
-- company's second filing. Migration 172's comment on the view still claims exactly that. It has
-- not been true since the first parser-version bump.
--
-- `round` is a `row_number()` computed in the SAME subquery as the "not yet parsed at the current
-- version" predicate. SQL applies `where` BEFORE window functions, so the window sees only filings
-- that still need work — and as a company's filings drain, its remaining ones RENUMBER. Parse a
-- company's round 1 and its old round 2 becomes round 1 on the very next query, putting it straight
-- back at the head, where `best_weight desc` hands it the page again. `round` is a moving target,
-- not a position in a round-robin.
--
-- MEASURED IN PRODUCTION 2026-09-06, mid-drain at parser version 20:
--
--   securities with >=1 filing re-read at v20 :   106   of 3,967 SEC-capable
--   median filings re-read per security       :  15.5
--   most for one security                     :   131   (Procter & Gamble, of its 164)
--
-- So 3,861 companies had not had a single filing re-read while P&G had had nearly its whole
-- history done twice over. Every signal read healthy throughout — ~240 filings/hour, thousands of
-- rows written, `ok` true, `remaining` falling — because the rows being written were CORRECT.
-- They were the wrong rows first: this is migration 156's defect exactly, in the one state its
-- test cannot reach.
--
-- WHY THE EXISTING TEST PASSES. `a-queue-must-reach-every-company.sql` builds nine filings, NONE
-- of them parsed, and asserts that a page of three spans three companies. That is the queue at
-- t=0, where the renumbering has nothing to renumber and the shipped view is genuinely
-- breadth-first. The defect only exists ACROSS SUCCESSIVE PAGES. Reproduced against the real view
-- before writing this: three companies, three annuals each, all parsed at an older version, then
-- three pages of one taken in a loop — the shipped view returns the heaviest company THREE TIMES.
-- The test is extended to drive that loop rather than inspect one page.
--
-- THE FIX IS WHERE THE PREDICATE SITS, NOT WHAT IT SAYS. Computing the window over every ELIGIBLE
-- filing and filtering afterwards makes `round` the filing's stable depth into its company's own
-- history — the thing the view's comment has always described. A company that has had k filings
-- read then sits at round k+1 and genuinely yields to every company still at round 1.
--
-- The blast radius of getting this wrong is a month: at ~240 filings/hour against 210,751 queued,
-- a drain that never yields spends its entire budget on a few hundred large caps, and the parser
-- corrections a version bump exists to deliver reach 3% of companies.

-- THIS IS THE SIXTH MIGRATION TO DEFINE THIS VIEW, AND THAT IS ITS OWN PROBLEM.
-- CLAUDE.md already records the rule — "four migrations defining one view with four column lists
-- means it is dropped on EVERY deploy... consolidating the definitions is the fix; adding a fifth
-- definer is not". This is the sixth. It is deliberate and narrow: the column list is byte-identical
-- to migration 172's, so the drop/recreate window this opens is one that already existed, and
-- consolidating six definers is a change with a different blast radius that deserves its own
-- testing rather than riding along with a correctness fix. Logged in todos.md with the count, so
-- the next definer is a decision rather than a habit. Do not add a seventh.
drop view if exists market.pending_segments;
create view market.pending_segments as
select security_id, accession_number, report_type, filing_date, filing_detail_url, cik,
       best_weight, round, already_read
from (
  select
    f.security_id, f.accession_number, f.report_type, f.filing_date, f.filing_detail_url,
    s.cik,
    -- A FILING WE HAVE ALREADY READ IS ONE WE ARE ALREADY SERVING FROM.
    (f.segments_parsed_at is not null) as already_read,
    -- THE WORK PREDICATE IS NOW A COLUMN, EVALUATED HERE AND APPLIED AFTER THE WINDOW. Moving it
    -- into the `where` below is what caused this migration; it must stay out of that clause.
    (
      f.segments_parsed_at is null
      or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
    ) as needs_work,
    coalesce(max(h.weight), 0) as best_weight,
    -- Over EVERY eligible filing, parsed or not, so a company's position in its own history is
    -- stable as the queue drains.
    row_number() over (
      partition by f.security_id
      order by
        -- Same vocabulary as the eligibility filter below, and it must be keyed the same way:
        -- a form list carried in two clauses drifts (migration 163 left exactly this second copy).
        coalesce((select ff.is_annual from market.filing_form ff
                   where ff.source_code = 'sec' and ff.form_code = f.report_type limit 1), false) desc,
        f.filing_date desc,
        f.accession_number
    ) as round
  from market.security_filing f
  join market.security s on s.security_id = f.security_id
  left join market.fund_holding_current h on h.security_id = f.security_id
  where
    -- ELIGIBILITY ONLY BELOW THIS LINE. Anything here that describes the STATE OF OUR WORK rather
    -- than the nature of the filing will renumber `round` again and reintroduce the defect.
    s.cik is not null
    -- The form vocabulary is keyed (source_code, form_code) and `사업보고서` is a real row with
    -- `carries_segments`, so an unqualified match would admit a Korean annual report into the SEC
    -- queue. `ff.source_code` is the REGULATOR, which is the honest scope for this path.
    --
    -- NOT `f.source_code`: measured 2026-09-05, `security_filing.source_code` holds the RESOURCE
    -- that wrote the row (`sec-submissions` 984, `sec-filings` 16) while `filing_form.source_code`
    -- holds the regulator (`sec`). Two vocabularies, one column name — filtering this view on
    -- `f.source_code = 'sec'` matches nothing and silently empties the entire SEC backlog.
    and exists (
      select 1 from market.filing_form ff
       where ff.source_code = 'sec' and ff.form_code = f.report_type and ff.carries_segments
    )
    and exists (
      select 1 from market.security_disclosure sd
       where sd.security_id = f.security_id and sd.capability = 'held'
    )
  group by f.security_id, f.accession_number, f.report_type, f.filing_date, f.filing_detail_url,
           s.cik, f.segments_parsed_at, f.segments_parser_version
) ranked
where needs_work
-- CORRECT WHAT WE ALREADY SERVE BEFORE READING SOMETHING NEW.
--
-- `segment_parser.version` re-queues every filing when it is bumped, so after a bump the queue
-- holds both filings we have never read and filings whose stored rows are now known to be wrong.
-- Measured 2026-09-05: of the 352 filings backing a SERVED split, **329 (93%) had been parsed by
-- an older parser** — so almost everything a reader sees was produced by code since fixed.
--
-- Breadth-first comes FIRST: `round` gives every company its latest annual before any company gets
-- a second year. WITHIN a round, a filing we have already read goes first, because re-reading it
-- corrects data on a page today where reading a new one only adds data nobody is being shown yet.
order by round, already_read desc, best_weight desc, accession_number;

comment on view market.pending_segments is
  'SEC filings whose XBRL instance has not been read for segment facts. Ordered BREADTH-FIRST: `round` is the filing''s STABLE depth into its own company''s history (annuals before quarterlies), computed over every eligible filing rather than only the outstanding ones — so a company that has had k filings read sits at round k+1 and yields to every company still at round 1. Computing it over the outstanding set instead makes it renumber as the queue drains, which put 3,861 of 3,967 filers at zero re-reads while one company had 131. Requires a CIK — that is the SEC path''s actual precondition, and without it enabling DART puts Korean filings in this queue, where `findInstanceUrl` cannot address them.';

-- A DROP TAKES THE GRANTS WITH IT, AND SUPERUSER CANNOT SEE THAT. Every one of this view's four
-- earlier definers re-grants for the same reason; omitting it here left `service_role` — which is
-- the role the edge function reads as — unable to select from the queue at all, so
-- `security-segments` would have failed on every run while the migration set applied cleanly four
-- times over. Caught by `every-table-is-reachable.sql`, which exists precisely because the
-- migration tests run as superuser and prove nothing about grants.
grant select on market.pending_segments to service_role;

notify pgrst, 'reload schema';
