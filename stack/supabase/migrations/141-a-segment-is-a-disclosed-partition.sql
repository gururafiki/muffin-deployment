-- REVENUE AND PROFIT PER BUSINESS LINE, FROM THE FILING'S OWN XBRL INSTANCE.
--
-- WHY THIS IS NOT AN EXTENSION OF `security-xbrl`. That resource reads `data.sec.gov`'s
-- companyfacts API, and **the XBRL REST APIs strip dimensions**. Measured 2026-08-28:
-- `companyconcept` for AAPL revenue returns keys `accn,end,filed,form,fp,frame,fy,start,val` —
-- no dimension field of any kind — and exactly ONE value per period ($416.16bn for FY2025). The
-- iPhone is not in it and no amount of paging will produce it.
--
-- WHERE THE NUMBERS COME FROM INSTEAD. Every filing publishes its XBRL instance as a separate
-- small file: AAPL's Q3-2025 10-Q is 778 KB with 165 contexts, AMZN's 10-K 2.07 MB, and the
-- pre-inline era is the same shape (AAPL's 2015 10-K is `aapl-20150926.xml`, no `_htm` suffix).
-- Contexts carry the dimensions the API drops. So this is an ordinary backlog resource over the
-- 30,072 10-K/10-Q/20-F filings `market.security_filing` ALREADY holds — no new scheduler, no new
-- executor, and it inherits `refresh_run`, `backlog_sample` and every pipeline panel for free.
--
-- (SEC's quarterly bulk datasets also carry a `segments` column, back to 2015q1, and are how every
-- expected value in the tests was first proven. They are 122 MB zipped / **542 MB** unpacked
-- against a 90 s / 256 MB worker, so they cannot be the production route. Do not re-propose them.)
--
-- ── THE ONE THING TO UNDERSTAND BEFORE READING ANY OF THIS DATA ───────────────────────────────
--
-- AN AXIS CAN CARRY SEVERAL OVERLAPPING SPLITS, EACH SUMMING TO THE SAME TOTAL.
--
-- Measured on Amazon's Q2-2025 10-Q: the `ProductOrService` axis carries a SEVEN-member split
-- (Online Stores, AWS, Advertising, Physical Stores, Subscription, Third-Party Seller, Other)
-- summing to 167,702 **and** a TWO-member split (Product, Service) summing to 167,702, while
-- `StatementBusinessSegments` carries a THREE-member split summing to 167,702 again. AWS appears
-- under two different axes with two different values (30,873 as a product line, 10,160 of
-- operating income as a segment).
--
-- `sum(value)` over an axis therefore DOUBLES Amazon's revenue and over the table TRIPLES it —
-- silently, in the right units, with no error and a perfectly plausible-looking chart.
--
-- Hence `partition_id`. **Nothing may aggregate across partitions, and nothing may aggregate
-- partition 0 at all.** Partition 1 is the finest split that reconciles to the filing's own
-- consolidated figure; higher numbers are coarser splits of the same total; 0 is a subtotal
-- (Apple's `ProductMember`, which is the sum of iPhone/iPad/Mac/Wearables) or a member the parser
-- could not place. Partition 0 rows are STORED rather than dropped because an upsert cannot
-- retract and because a coarse split is sometimes all a filer gives.

-- ── The axes worth keeping — a CONTROL TABLE, because the name is the only thing that differs ──
--
-- Diageo's 20-F parses to Spirits/Beer/Ready-to-Drink through `ifrs-full:ProductsAndServicesAxis`
-- where Apple uses `srt:ProductOrServiceAxis`. Same parser, same shape, different spelling — which
-- is the `metric_source_field` lesson again: a provider's vocabulary is DATA. Adding a taxonomy
-- (including a Japanese or Korean one) is rows here, not a branch in TypeScript.
--
-- An ALLOWLIST is mandatory rather than tidy. Apple's instance carries 206 dimensioned facts of
-- which only 44 are segmentations; the rest are fair-value hierarchy levels, equity components,
-- restatement scenarios and concentration-risk benchmarks. Treating those as business lines would
-- invent segments called "Level 2" and "Retained Earnings".
create table if not exists market.segment_axis (
  taxonomy text not null,
  axis     text not null,
  -- `product` / `business` / `geography` SEGMENT a company. `qualifier` does not: it narrows a
  -- fact without sub-dividing it, and Alphabet tags every segment figure with
  -- `ConsolidationItems=OperatingSegments`. Rejecting two-dimension facts outright would lose all
  -- of Alphabet's segment data; accepting any second dimension would invent segments from the
  -- fair-value table. So a qualifier is allowed ALONGSIDE a segment axis, and an unknown axis
  -- disqualifies the fact.
  kind     text not null check (kind in ('product', 'business', 'geography', 'qualifier')),
  priority integer not null default 100,
  primary key (taxonomy, axis)
);

comment on table market.segment_axis is
  'Which XBRL dimensions express a business segmentation, per taxonomy. us-gaap and ifrs-full spell the same idea differently, so the axis name is data rather than code — adding a taxonomy is rows. `kind = qualifier` marks a dimension that narrows a fact without sub-dividing it (Alphabet tags every segment figure with ConsolidationItems=OperatingSegments).';

insert into market.segment_axis (taxonomy, axis, kind, priority) values
  -- us-gaap. Verified against AAPL and AMZN 10-Qs, 2026-08-28.
  ('us-gaap', 'srt:ProductOrServiceAxis',                  'product',   100),
  ('us-gaap', 'us-gaap:StatementBusinessSegmentsAxis',     'business',   90),
  ('us-gaap', 'srt:StatementGeographicalAxis',             'geography',  50),
  ('us-gaap', 'srt:ConsolidationItemsAxis',                'qualifier',   0),
  ('us-gaap', 'us-gaap:StatementConsolidationItemsAxis',   'qualifier',   0),
  -- ifrs-full, for the 787 non-US securities that file a 20-F. Verified against Diageo's FY2025
  -- 20-F, which parses to Spirits 22,166 / Beer / Ready-to-Drink plus four geographies.
  ('ifrs-full', 'ifrs-full:ProductsAndServicesAxis',       'product',   100),
  ('ifrs-full', 'ifrs-full:SegmentsAxis',                  'business',   90),
  ('ifrs-full', 'ifrs-full:GeographicalAreasAxis',         'geography',  50),
  ('ifrs-full', 'ifrs-full:OperatingSegmentsAxis',         'business',   90),
  ('ifrs-full', 'ifrs-full:SegmentConsolidationItemsAxis', 'qualifier',   0)
on conflict (taxonomy, axis) do update
  set kind = excluded.kind, priority = excluded.priority;

-- ── The facts ─────────────────────────────────────────────────────────────────────────────────
insert into market.data_source (code, name, priority) values
  ('sec-segments', 'SEC filing segment disclosure', 260)
on conflict (code) do update set name = excluded.name, priority = excluded.priority;

create table if not exists market.security_segment (
  security_id   uuid not null references market.security (security_id) on delete cascade,
  axis          text not null,
  member_code   text not null,
  metric_code   text not null references market.metric (code),
  -- `period_type` IS IN THE KEY, and migration 106 is why. A fiscal-year end is BOTH an annual
  -- period and a fourth-quarter one, so without it an annual revenue is silently replaced by three
  -- months of it: wrong by a factor of four, in the right units, with no error and an identical
  -- row count. Both the upsert's `onConflict` and the resource's dedupe key carry it too.
  period_type   text not null check (period_type in ('annual', 'quarter')),
  period_ending date not null,
  period_start  date,
  value         numeric not null,
  -- READ FROM THE FILING'S UNIT, never defaulted. A foreign private issuer reports in its own
  -- currency, and the country cannot be used to guess it — Diageo is a British company that files
  -- its 20-F in USD (measured: consolidated revenue 27,964,000,000 under `iso4217:USD`).
  currency_code text references market.currency (code),
  -- See the header. 1 = the finest split that reconciles, 2+ = coarser splits of the same total,
  -- 0 = a subtotal or unplaceable. NOTHING MAY AGGREGATE ACROSS THESE.
  partition_id  smallint not null default 0,
  -- Provenance, so a restated figure is traceable to the document that restated it.
  accession_number text,
  source_code   text not null references market.data_source (code),
  as_of         timestamptz not null default now(),
  primary key (security_id, axis, member_code, metric_code, period_type, period_ending)
);

comment on table market.security_segment is
  'Revenue and operating income per disclosed business line, parsed from the filing''s XBRL instance. AGGREGATE WITHIN ONE partition_id ONLY: an axis can carry several overlapping splits that each sum to the consolidated total (Amazon discloses three), so summing an axis doubles the company''s revenue and summing the table triples it. partition_id 0 is a subtotal and must never be summed.';

comment on column market.security_segment.partition_id is
  'Which disclosed split this member belongs to. 1 is the finest split that reconciles to the filing''s own consolidated figure; 2+ are coarser splits of the same total; 0 is a subtotal (Apple''s ProductMember is the sum of iPhone/iPad/Mac/Wearables) or a member the parser could not place.';

-- ADDED BY MIGRATION 154 and declared here, because migration 150's `security_segment_latest`
-- lists its columns EXPLICITLY and runs BEFORE 154 — so a column introduced later cannot appear in
-- the view without the view's own file failing on the first pass. `if not exists` keeps this
-- idempotent on a database where 154 already added it.
alter table market.security_segment add column if not exists reconciled_to numeric;

comment on column market.security_segment.reconciled_to is
  'The figure this member''s split was accepted against — the filing''s own consolidated value for a flat split, the parent member''s value for a nested one. NULL for partition 0, which was never placed. Stored so a guard can ask "does this split still add up" without comparing against a second, independently derived total.';

create index if not exists security_segment_lookup_idx
  on market.security_segment (security_id, metric_code, period_type, period_ending desc);
create index if not exists security_segment_member_idx
  on market.security_segment (member_code);

-- ── The shared vocabulary — what makes CROSS-COMPANY comparison possible ──────────────────────
--
-- A filer names its own members: Amazon says `amzn:AmazonWebServicesMember`, Alphabet
-- `goog:GoogleCloudMember`, Microsoft `msft:IntelligentCloudMember`. Those are the same business
-- and nothing in the filings says so. `segment_concept` is the shared noun and `segment_alias`
-- maps each filer's spelling onto it — exactly the `metric` / `metric_source_field` split, for the
-- same reason: the mapping is editorial, so it is a row a human can fix in Studio.
--
-- BE HONEST ABOUT WHAT THIS CANNOT DO. It can only compare what companies actually DISCLOSE.
-- Alphabet does not break out Pixel (it sits inside "Google other"), so an iPhone-vs-Pixel
-- comparison is impossible from filings however this table is populated. AWS vs Google Cloud vs
-- Microsoft's Intelligent Cloud is possible, because all three disclose it.
create table if not exists market.segment_concept (
  code        text primary key,
  name        text not null,
  parent_code text references market.segment_concept (code),
  -- Where this business line sits in the muffin taxonomy, so a segment can WEIGHT a security's
  -- classification (migration 142). Nullable: a concept may be worth naming before anyone has
  -- decided which sector it belongs to.
  node_id     uuid references market.taxonomy_node (node_id) on delete set null
);

comment on table market.segment_concept is
  'The shared vocabulary of business lines — "cloud-infrastructure", "smartphones" — that a filer''s own member codes are mapped onto. Editable in Studio; a redeploy must not revert a curation.';

create table if not exists market.segment_alias (
  member_code  text not null,
  concept_code text not null references market.segment_concept (code) on delete cascade,
  -- Scoped to the security, because member codes are NOT globally unique: `us-gaap:ProductMember`
  -- means something different in every filing that uses it. Null means "any filer using this
  -- code", which is only safe for company-extension members that carry the filer's own prefix.
  security_id  uuid references market.security (security_id) on delete cascade
);

-- TWO PARTIAL INDEXES, NOT A PRIMARY KEY. A primary key implies NOT NULL on every column it
-- names, so `primary key (member_code, concept_code, security_id)` would forbid the generic
-- mapping this table is half designed for — and it fails at INSERT time, not at migration time.
-- Note the consequence recorded in CLAUDE.md: a partial unique index is NOT covered by a plain
-- `on conflict (a,b)`, so every write here uses `on conflict do nothing` with no target.
create unique index if not exists segment_alias_scoped_idx
  on market.segment_alias (member_code, concept_code, security_id) where security_id is not null;
create unique index if not exists segment_alias_generic_idx
  on market.segment_alias (member_code, concept_code) where security_id is null;

comment on table market.segment_alias is
  'Maps a filer''s own XBRL member code onto a shared concept. Scoped per security because member codes are not globally unique — `us-gaap:ProductMember` means something different in every filing.';

-- ── The backlog ───────────────────────────────────────────────────────────────────────────────
--
-- A FILED DOCUMENT NEVER CHANGES, so this needs no 30-day negative cache. Every other backlog in
-- this schema carries one because a provider's "no data" might become "data" next month; a 10-Q
-- that disclosed no segments in 2019 will still disclose none in 2030. `segments_parsed_at`
-- therefore records that we LOOKED, permanently.
--
-- The re-parse escape hatch is `parser_version`, because the thing that DOES change is this
-- pipeline's own understanding — adding an axis to `segment_axis` means old filings hold facts we
-- would now keep. Bumping `market.segment_parser.version` re-queues everything, with no deploy and
-- no hand-written UPDATE.
alter table market.security_filing add column if not exists segments_parsed_at timestamptz;
alter table market.security_filing add column if not exists segments_parser_version smallint;

comment on column market.security_filing.segments_parsed_at is
  'When this filing''s XBRL instance was read for segment facts. NOT a negative cache with an expiry: a filed document is immutable, so "this filing discloses no segments" is permanent. Re-reading is driven by segments_parser_version instead.';

create table if not exists market.segment_parser (
  singleton boolean primary key default true check (singleton),
  version   smallint not null
);
insert into market.segment_parser (singleton, version) values (true, 1)
on conflict (singleton) do nothing;   -- DO NOTHING: an operator bump must survive the next deploy.

comment on table market.segment_parser is
  'One row. Bumping `version` re-queues every filing for segment parsing — the supported way to pick up a newly added `segment_axis` without a deploy or a hand-written update.';

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
  -- The forms that carry audited segment disclosure. A 6-K or 8-K is an event, not accounts, and
  -- a foreign private issuer files 20-F/40-F INSTEAD OF 10-K/10-Q rather than as well.
  f.report_type in ('10-K', '10-Q', '20-F', '40-F')
  and s.cik is not null
  -- An ANTI-JOIN over the work grain, never an `order by ... limit`. `derive_security_metrics`
  -- shipped the latter and returned the same page for ever while `written` read as throughput.
  and (
    f.segments_parsed_at is null
    or coalesce(f.segments_parser_version, 0) < (select p.version from market.segment_parser p)
  )
group by f.security_id, f.accession_number, f.report_type, f.filing_date, f.filing_detail_url, s.cik
-- Weight first so the companies anyone is actually looking at are parsed first, with the accession
-- as a UNIQUE tiebreak — a paged read over a non-total ordering is how a fixture becomes flaky and
-- a backlog re-reads its own head.
order by best_weight desc, f.accession_number;

comment on view market.pending_segments is
  'Filings whose XBRL instance has not been read for segment facts. Ordered by fund weight so the largest holdings are parsed first.';

-- ── Serving ───────────────────────────────────────────────────────────────────────────────────
--
-- The latest ANNUAL figure per (security, axis, member), revenue beside operating income so a
-- margin is available without a second query. Restricted to `partition_id = 1` — the finest
-- reconciling split — because that is the only set a caller can safely sum, and serving anything
-- else invites exactly the double count the header describes.

-- ── `security_segment_current` IS DEFINED ONCE, IN MIGRATION 157 ──────────────────────────────
-- It used to be defined here too. FIVE migrations (141, 148, 149, 150, 157) each carried a
-- `create view` for it with a different column list, and `create or replace view` can only APPEND
-- columns — so the earliest definer could never impose the latest one's shape and had to DROP,
-- taking its dependents with it. That is a real window on EVERY deploy, roughly sixteen files
-- wide, in which the view and the segment spine do not exist. Tolerable only while nothing
-- user-facing read them, which stopped being true when the stock page began drawing business
-- lines. The header above still records WHY the view carries what it carries; only the DDL moved.


-- ── Grants and RLS ────────────────────────────────────────────────────────────────────────────
-- `security_segment_current` is granted where it is defined, in migration 157.
grant select on market.segment_axis, market.security_segment, market.segment_concept,
                market.segment_alias, market.segment_parser
  to anon, authenticated, service_role;
grant insert, update, delete on market.segment_axis, market.security_segment,
                                market.segment_concept, market.segment_alias, market.segment_parser
  to service_role;
grant select on market.pending_segments to service_role;

alter table market.segment_axis     enable row level security;
alter table market.security_segment enable row level security;
alter table market.segment_concept  enable row level security;
alter table market.segment_alias    enable row level security;
alter table market.segment_parser   enable row level security;
drop policy if exists segment_axis_read     on market.segment_axis;
drop policy if exists security_segment_read on market.security_segment;
drop policy if exists segment_concept_read  on market.segment_concept;
drop policy if exists segment_alias_read    on market.segment_alias;
drop policy if exists segment_parser_read   on market.segment_parser;
create policy segment_axis_read     on market.segment_axis     for select using (true);
create policy security_segment_read on market.security_segment for select using (true);
create policy segment_concept_read  on market.segment_concept  for select using (true);
create policy segment_alias_read    on market.segment_alias    for select using (true);
create policy segment_parser_read   on market.segment_parser   for select using (true);

notify pgrst, 'reload schema';
