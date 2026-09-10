-- KOREA FILES WITH DART, and everything downstream already knows how to read it.
--
-- Segment disclosure has been SEC-only: 3,516 securities can have it and 8,834 equities cannot,
-- which is why it is a coverage DIMENSION rather than a required facet. Korea is the largest gap
-- that is actually addressable — measured 2026-09-05 against the live API, **445 of 462** Korean
-- equities (96%) match a DART annual report.
--
-- Almost nothing here is new machinery. `market.segment_axis` already carries all four axes DART
-- uses (`ifrs-full:ProductsAndServicesAxis`, `SegmentsAxis`, `GeographicalAreasAxis`,
-- `SegmentConsolidationItemsAxis` — the same ones Diageo's 20-F uses), `xbrl_concept` already
-- carries the IFRS elements, and `parseFacts` matches on the LOCAL name so `ifrs-full:Revenue`
-- matches the catalogued `Revenue`. Korean filings land in `security_filing` and inherit its
-- `segments_parsed_at` cursor and `segment_parser.version` re-queue for free.

-- ── the source, and the form it files ────────────────────────────────────────────────────────────
-- `security_filing.source_code` is a foreign key to `data_source`, so this row must exist BEFORE a
-- resource writes one. Migration 088's lesson: a resource writing an unseeded `source_code` dies on
-- its FIRST REAL RUN and no migration test catches it, because no resource runs there.
insert into market.data_source (code, name, priority) values
  ('dart', 'DART (Korea) — Financial Supervisory Service', 250)
on conflict (code) do update set name = excluded.name;

-- 사업보고서 is the Korean annual report. `carries_segments` puts it in a segment backlog at all;
-- `is_annual` makes it sort ahead of quarterlies within a company, which is what breadth-first
-- ordering depends on.
-- Keyed (source_code, form_code) and `source_code` references `disclosure_source`, NOT
-- `data_source` — the two both have a row called `sec` and they are different tables.
insert into market.filing_form (source_code, form_code, is_annual, carries_segments) values
  ('dart', '사업보고서', true, true)
on conflict (source_code, form_code) do update
  set is_annual = excluded.is_annual, carries_segments = excluded.carries_segments;

-- ── who DART can serve ───────────────────────────────────────────────────────────────────────────
-- The first row this table has ever had. SEC deliberately has none: it is registration-driven
-- rather than jurisdictional, so 787 non-US securities reach it through a 20-F.
insert into market.disclosure_coverage (source_code, country_iso2) values ('dart', 'KR')
on conflict do nothing;

-- ENABLED HERE, DELIBERATELY AND ONCE. `enabled` is excluded from migration 163's `DO UPDATE` so an
-- operator who switches a source off in Studio is not overridden by the next deploy. This is the
-- one-time flip that turns Korean securities from `resolvable` into `held`, and it is what makes
-- `security-kr-segments` a resource with work to do rather than an advertisement for work nothing
-- can perform.
update market.disclosure_source set enabled = true where code = 'dart';

-- ── the SEC backlog must not pick up Korean filings ─────────────────────────────────────────────
-- THE INTEGRATION HAZARD, and it is created by the line above. `pending_segments`' only protection
-- against a non-SEC filing today is `security_disclosure.capability = 'held'` — which enabling DART
-- makes true for Korea. Without this the SEC resource would call `findInstanceUrl(cik => null,
-- rcept_no)` on every Korean filing and fail on all of them.
--
-- A CIK is the SEC path's actual precondition, so requiring it is a statement of fact rather than a
-- defensive filter. `pending_kr_segments` below requires a DART filer id symmetrically.
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
    coalesce(max(h.weight), 0) as best_weight,
    row_number() over (
      partition by f.security_id
      order by
        -- Same vocabulary as the eligibility filter above, and it must be keyed the same way:
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
    and (
      f.segments_parsed_at is null
      or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
    )
  group by f.security_id, f.accession_number, f.report_type, f.filing_date, f.filing_detail_url,
           s.cik, f.segments_parsed_at
) ranked
-- CORRECT WHAT WE ALREADY SERVE BEFORE READING SOMETHING NEW.
--
-- `segment_parser.version` re-queues every filing when it is bumped, so after a bump the queue
-- holds both filings we have never read and filings whose stored rows are now known to be wrong.
-- Measured 2026-09-05: of the 352 filings backing a SERVED split, **329 (93%) had been parsed by
-- an older parser** — so almost everything a reader sees was produced by code since fixed, while
-- the queue worked through 213,500 filings at 20 a run.
--
-- Breadth-first still comes first: `round` keeps migration 156's property that every company gets
-- its latest annual before any gets a second year. WITHIN a round, a filing we have already read
-- goes first, because re-reading it corrects data on a page today, where reading a new one only
-- adds data nobody is being shown yet. Bounded by construction — 19,849 filings have ever been
-- parsed against 213,500 queued — so this reorders a head, it does not starve new work.
order by round, already_read desc, best_weight desc, accession_number;

comment on view market.pending_segments is
  'SEC filings whose XBRL instance has not been read for segment facts. Ordered BREADTH-FIRST: `round` is the filing''s depth into its own company''s history (annuals before quarterlies), so one pass covers every filer''s latest annual before any company''s second filing. Requires a CIK — that is the SEC path''s actual precondition, and without it enabling DART puts Korean filings in this queue, where `findInstanceUrl` cannot address them.';

grant select on market.pending_segments to service_role;

-- ── the Korean backlog ───────────────────────────────────────────────────────────────────────────
-- Same shape and the same breadth-first ordering, keyed on the DART filer id instead of a CIK.
-- Migration 156's lesson applies identically: ordering by fund weight alone parsed 14 companies out
-- of 3,500, because weight belongs to the SECURITY and every filing of a company shares it.
drop view if exists market.pending_kr_segments;
create view market.pending_kr_segments as
select security_id, accession_number, report_type, filing_date, filer_id, best_weight, round
from (
  select
    f.security_id, f.accession_number, f.report_type, f.filing_date,
    sf.filer_id,
    coalesce(max(h.weight), 0) as best_weight,
    row_number() over (
      partition by f.security_id
      order by
        -- Same vocabulary as the eligibility filter above, and it must be keyed the same way:
        -- a form list carried in two clauses drifts (migration 163 left exactly this second copy).
        coalesce((select ff.is_annual from market.filing_form ff
                   where ff.source_code = 'dart' and ff.form_code = f.report_type limit 1), false) desc,
        f.filing_date desc,
        f.accession_number
    ) as round
  from market.security_filing f
  join market.security_filer sf
    on sf.security_id = f.security_id and sf.source_code = 'dart'
  left join market.fund_holding_current h on h.security_id = f.security_id
  where
    f.source_code = 'dart'
    and exists (
      select 1 from market.filing_form ff
       where ff.source_code = 'dart' and ff.form_code = f.report_type and ff.carries_segments
    )
    and (
      f.segments_parsed_at is null
      or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
    )
  group by f.security_id, f.accession_number, f.report_type, f.filing_date, sf.filer_id
) ranked
order by round, best_weight desc, accession_number;

comment on view market.pending_kr_segments is
  'Korean filings whose XBRL has not been read. Separate from `pending_segments` because the two are fetched completely differently — SEC by CIK and accession from a directory listing, DART by receipt number from an API that returns a ZIP — while sharing `security_filing`, its `segments_parsed_at` cursor and the `segment_parser.version` re-queue. Breadth-first, so every Korean company gets its latest annual before any gets a second year.';

grant select on market.pending_kr_segments to service_role;

-- ── phase B needs a cursor, or its page is not a page ────────────────────────────────────────────
--
-- Phase B walks one company's whole filing history. Written as `select … limit 8` it returns the
-- SAME eight companies on every run, for ever — the exact defect `derive_security_metrics` shipped
-- with (two production calls returning byte-identical `written: 7386, remaining: 104925`), and the
-- one `pending_industry` ran for months. A page's source set must be an ANTI-JOIN over what is
-- already done, never an ordering.
--
-- A CURSOR, NOT A NEGATIVE CACHE. Korean companies keep filing: an annual report lands every
-- spring, so "we have walked this company" is true for a season and never permanently. This is
-- `insider_fetched_at`'s shape, not `%_missing_at`'s — and it is deliberately not named
-- `%_missing_at`, because those record a settled absence and this records a visit.
alter table market.security_filer
  add column if not exists history_walked_at timestamptz;

drop view if exists market.pending_kr_history;
create view market.pending_kr_history as
select
  sf.security_id,
  sf.filer_id,
  coalesce(max(h.weight), 0) as best_weight,
  sf.history_walked_at
from market.security_filer sf
join market.security s on s.security_id = sf.security_id
left join market.fund_holding_current h on h.security_id = sf.security_id
where sf.source_code = 'dart'
  and (
    sf.history_walked_at is null
    -- Re-walk after a season. Phase A stops sweeping once `mapped_at` is set, so this is the ONLY
    -- path by which a newly filed annual report is ever discovered — a permanent mark here would
    -- freeze the Korean universe at whatever it held the day discovery finished.
    or sf.history_walked_at < now() - interval '90 days'
  )
group by sf.security_id, sf.filer_id, sf.history_walked_at
-- Never walked first, then the largest holdings — so a fresh company is reached before an old one
-- is revisited, and the re-walks arrive in the order they matter.
order by (sf.history_walked_at is not null), best_weight desc, sf.security_id;

comment on view market.pending_kr_history is
  'Korean filers whose filing history has not been walked in the last 90 days. A CURSOR rather than a negative cache: companies keep filing, so an absence here is never permanent, and after `dart_discovery_cursor.mapped_at` is set this is the only way a new annual report is discovered.';

grant select on market.pending_kr_history to service_role;

-- ── the discovery cursor ─────────────────────────────────────────────────────────────────────────
-- DART caps `list.json` at a THREE-MONTH window whenever `corp_code` is absent (measured: a 9-month
-- request answers `status 100`, "corp_code가 없는 경우 검색기간은 3개월만 가능합니다"). The mapping
-- sweep therefore walks windows, and 61 such calls took 247 s — far more than one 90 s worker, so it
-- cannot be a single pass and needs somewhere to remember where it stopped.
create table if not exists market.dart_discovery_cursor (
  singleton    boolean primary key default true check (singleton),
  -- The window most recently swept, walking backwards from the present.
  window_end   date,
  -- WHERE INSIDE THAT WINDOW. A window is ~35 calls (Y and K, ~10 pages each at page_count=100) and
  -- DART answers in ~3.5 s from the node — measured 2026-09-05, three consecutive pages at 3.45,
  -- 3.51, 3.45 s. A 70 s run therefore affords ~15 calls and CANNOT finish a window. Without these
  -- two columns the sweep advances `window_end` on the deadline regardless, recording a window as
  -- swept when two thirds of its pages were never read — a refused sweep reading as a finished one,
  -- which is the `exchange-listings` 429 defect exactly. The companies on those pages are then
  -- missed silently, and phase A never returns to that window.
  cls          text not null default 'Y' check (cls in ('Y','K')),
  page         int  not null default 1 check (page >= 1),
  -- Set once every listed filer we hold has been mapped, so the sweep stops re-walking history and
  -- the resource moves on to per-company history, which has no window limit at all.
  mapped_at    timestamptz,
  updated_at   timestamptz not null default now()
);
-- Re-applied on every deploy, so the columns are added rather than assumed — the table already
-- exists in production from an earlier apply of this same file.
alter table market.dart_discovery_cursor
  add column if not exists cls  text not null default 'Y',
  add column if not exists page int  not null default 1;
insert into market.dart_discovery_cursor (singleton) values (true) on conflict do nothing;

grant select, insert, update on market.dart_discovery_cursor to service_role;

-- ── scheduling ───────────────────────────────────────────────────────────────────────────────────
-- REGISTERED BUT OUT OF THE ROTATION, exactly as `security-segments` is. `cron_next()` counts only
-- enabled resources, so `enabled = false` keeps these out of the shared five-minute sweep while
-- keeping the ROW — which is what the "every backlog resource is actually SCHEDULED" guard reads,
-- and what `resource_health.scheduled` uses to tell a retired resource from a stalled one.
--
-- They need their own jobs because one Korean filing takes 73.5 s to fetch, measured: putting that
-- in a rotation shared with 40 other resources would hold the slot for the whole budget.
insert into market.cron_resource (position, resource) values
  (410, 'kr-filings'),
  (420, 'security-kr-segments')
on conflict (position) do update set resource = excluded.resource;

update market.cron_resource set enabled = false
 where resource in ('kr-filings', 'security-kr-segments');

do $$ begin
  -- :04, :09, :14 … offset from the rotation's `*/5` AND from segments' `2-59/5`, so three passes
  -- never fire in the same minute on one Always-Free node.
  --
  -- FIVE MINUTES WITH A FOUR-MINUTE TTL. The TTL must be SHORTER than the interval or the resource
  -- self-skips half its firings — `security-segments` shipped with a 10-minute TTL on a 5-minute
  -- cron and did exactly that, and `derive-classifications` still skips 29 days in 30.
  perform cron.schedule('muffin-kr-segments', '4-59/5 * * * *',
    $c$ select market.cron_post('security-kr-segments') $c$);
  -- Discovery is cheap per call but needs many, and DART answers in ~3.5 s from the node (measured
  -- 3.45/3.51/3.45), so a 70 s run affords ~15 calls against a window's ~35: it covers PART of a
  -- window per run and resumes at the exact (cls, page) it stopped on. Quarter-hourly converges in
  -- a day or so, after which it only picks up newly filed reports.
  perform cron.schedule('muffin-kr-filings', '11-59/15 * * * *',
    $c$ select market.cron_post('kr-filings') $c$);
exception when others then
  raise notice '  --  could not schedule pg_cron job (%): it will be scheduled on the next apply', sqlerrm;
end $$;

notify pgrst, 'reload schema';
