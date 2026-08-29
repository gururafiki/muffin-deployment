-- THE FILING INDEX IS SHALLOW BECAUSE OF A `limit=40`, NOT BECAUSE SEC IS.
--
-- MEASURED 2026-08-28 against production. `security_filing` holds 126,312 rows and looks healthy,
-- but the accounts forms by year are: **2026: 8,450 · 2024: 8,070 · 2021: 27 · 2018: 1 · 2015: 4**.
-- It is a RECENT-FILINGS table wearing a filing index's name. The cause is one parameter —
-- `security-filings` calls `equity/fundamental/filings?...&limit=40`, and forty filings is two to
-- three years for a company that also files 8-Ks and Form 4s.
--
-- That matters now because `security-segments` (migration 141) reads each filing's XBRL instance,
-- and the depth of the segment history is exactly the depth of this table.
--
-- THE FIX IS A DIFFERENT ENDPOINT, NOT A BIGGER LIMIT. SEC's own submissions API returns the
-- filer's COMPLETE history — 1,000 filings inline plus paginated older pages (Apple: 1,000 recent
-- back to 2015-06, then one page of 1,242 covering 1994-2015) — in ONE keyless request.
--
-- AND IT CARRIES THE INDUSTRY CODE IN THE SAME RESPONSE. `sic` / `sicDescription` sit at the top
-- level (Apple: 3571, "Electronic Computers"). This file's most-repeated lesson is "the answer is
-- already in a response you fetch"; it has been rediscovered six times here, so the SIC
-- classification in migration 143's family costs **zero** additional requests.

-- SEEDED BESIDE THE RESOURCE THAT WRITES IT. Migration 88 shipped a resource writing
-- `source_code: 'sec'` with no such row, and the FIRST REAL RUN in production died on the foreign
-- key and took the whole batch with it — invisible to every migration pass, because no resource
-- runs against a test database. `logic-check.ts` now fails on any unseeded literal, and it caught
-- this one.
insert into market.data_source (code, name, priority) values
  ('sec-submissions', 'SEC submissions index (complete filing history)', 255)
on conflict (code) do update set name = excluded.name, priority = excluded.priority;

-- ── The cursor ────────────────────────────────────────────────────────────────────────────────
--
-- A CURSOR, NOT A NEGATIVE CACHE, and the distinction is the same one `filings_fetched_at` and
-- `insider_fetched_at` already make: companies keep filing, so "no new 10-K" is never a permanent
-- fact about a company. Deliberately NOT named `%_missing_at`, which
-- `tests/negative-caches-are-classified.sql` reads as a settled absence.
alter table market.security add column if not exists filing_history_fetched_at timestamptz;
alter table market.security add column if not exists sic text;
alter table market.security add column if not exists sic_description text;

comment on column market.security.filing_history_fetched_at is
  'When SEC''s submissions API was last walked for this filer''s COMPLETE filing history. A cursor, not a negative cache — companies keep filing.';
comment on column market.security.sic is
  'SEC''s Standard Industrial Classification for the filer, from the submissions response we already fetch for the filing history. A real four-level hierarchy, and the only industry code that comes from the registrant rather than a provider''s opinion.';

-- ── Whether a filing has XBRL at all ──────────────────────────────────────────────────────────
--
-- The submissions response states this per filing (`isXBRL` / `isInlineXBRL`), and it is worth
-- storing because the alternative is finding out the expensive way. XBRL only became mandatory in
-- phases from 2009, so a full history reaches thousands of filings that can never yield a segment
-- — and `security-segments` would spend TWO requests on each of them (the directory listing, then
-- a 404) to learn what this column already knows.
alter table market.security_filing add column if not exists is_xbrl boolean;

comment on column market.security_filing.is_xbrl is
  'Whether SEC reports this filing as carrying XBRL. NULL means unknown — rows written before the submissions walk — and is treated as "worth trying", because every filing since 2019 has it.';

-- ── The backlog ───────────────────────────────────────────────────────────────────────────────
drop view if exists market.pending_filing_history;
create view market.pending_filing_history as
select
  s.security_id,
  s.cik,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
left join market.fund_holding_current h on h.security_id = s.security_id
where s.cik is not null
  -- ONE REQUEST BUYS THE WHOLE HISTORY, so this is re-walked rarely: the only thing that changes
  -- is the addition of new filings, which `security-filings` already picks up every rotation. 30
  -- days keeps the SIC and any back-filed amendments current without re-downloading ~10,000
  -- multi-megabyte payloads a week.
  and (s.filing_history_fetched_at is null
       or s.filing_history_fetched_at < now() - interval '30 days')
group by s.security_id, s.cik
order by best_weight desc, s.security_id;

comment on view market.pending_filing_history is
  'Filers whose complete filing history has not been walked from SEC''s submissions API in the last 30 days. Ordered by fund weight so the largest holdings gain depth first.';

grant select on market.pending_filing_history to service_role;

-- ── `pending_segments` learns to skip what can never answer ───────────────────────────────────
--
-- Redefined here rather than in 141 so the reason travels with the column. `create or replace`
-- with an IDENTICAL column list is safe in both orders: 141 runs first each deploy and restores
-- the unfiltered form, then this file narrows it again. Changing a column would not be — that is
-- the trap that killed two deploys.
-- DROP BEFORE CREATE, because migration 156 adds a `round` column to this view and every migration
-- re-runs in order on every deploy. `create or replace view` can only APPEND columns, so without
-- the drop this file spends every pass trying to shrink 156's definition back to its own and fails
-- the deploy with `cannot drop columns from view`. Fourth time this shape has cost a deploy.
drop view if exists market.pending_segments;
create view market.pending_segments as
select
  f.security_id,
  f.accession_number,
  f.report_type,
  f.filing_date,
  f.filing_detail_url,
  s.cik,
  coalesce(max(h.weight), 0) as best_weight
from market.security_filing f
join market.security s on s.security_id = f.security_id
left join market.fund_holding_current h on h.security_id = f.security_id
where
  f.report_type in ('10-K', '10-Q', '20-F', '40-F')
  and s.cik is not null
  -- NULL IS "WORTH TRYING", not "no". Every row written before the submissions walk has no value
  -- here, and every filing since 2019 carries XBRL — so treating unknown as absent would empty the
  -- backlog of exactly the recent filings that do have segments. `is distinct from false` says
  -- that precisely; `<> false` would drop the NULLs, which is the SQL twin of the falsy-NULL gate
  -- that once made a currency guard decline to fire on the security it was built for.
  and f.is_xbrl is distinct from false
  and (
    f.segments_parsed_at is null
    or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
  )
group by f.security_id, f.accession_number, f.report_type, f.filing_date, f.filing_detail_url, s.cik
order by best_weight desc, f.accession_number;

notify pgrst, 'reload schema';
