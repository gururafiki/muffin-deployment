-- Materialise the segment spine — IDEMPOTENT.
--
-- MEASURED, at a deliberately production-sized 1,920,000 segment facts (3,000 filers x 8 members
-- x 20 periods x 4 metrics — conservative: 3,500 SEC filers x ~20 filings x ~10 members x 6 metrics
-- x 2 period types is roughly 8M):
--
--     security_segment_current, filtered to ONE security      3.8 ms
--     security_segment_current, whole view                 6,108 ms
--     security_segment_latest,  whole view                 2,892 ms
--     pending_segment_alias                                7,508 ms   <- the 8s role timeout
--
-- So the APP is fine and the DASHBOARD is not. Every whole-table reader — the curation queue, the
-- comparability table, the geography breakdown, and four Grafana panels — sits a few hundred
-- thousand rows away from `57014 canceling statement due to statement timeout`, while every
-- single-security probe says the view is healthy. Fourth occurrence of that shape here, after
-- `fund_sector_weight`, `security_facets` and `price_series`.
--
-- AN INDEX WAS THE FIRST HYPOTHESIS AND THE NUMBER DID NOT MOVE. A covering index on
-- `(security_id, axis, member_code, metric_code, period_ending desc) where partition_id = 1` gave
-- 6,225 ms against 6,108 — noise. The cost is intrinsic: `security_segment_latest` dense-ranks the
-- whole table and `security_segment_current` then runs `distinct on` plus three laterals over all
-- of it. Migration 80 met exactly this and the lesson was that materialising makes the cost
-- BOUNDED for every access pattern, which tuning one query never is.
--
-- THE SPINE IS `select * from` THE VIEW, DELIBERATELY. Restating the pivot would be the
-- same-fact-in-two-places this schema has already been bitten by (the venue map drifted to 54 rows
-- against 38). Defined this way the two cannot disagree about anything except FRESHNESS, and an
-- hour of staleness on a number that changes when a decade-old filing is parsed is not a cost.
--
-- Two access patterns, two objects, and that is the whole design:
--   `security_segment_current` — one security, live, 3.8 ms. What a stock page reads.
--   `security_segment_spine`   — every security, materialised. What an aggregate reads.

-- ── The spine ─────────────────────────────────────────────────────────────────────────────────
-- `IF EXISTS` DOES NOT PROTECT AGAINST A RELKIND MISMATCH: `drop view if exists` on a matview
-- raises `is not a view` and the converse also raises, so NEITHER ORDERING OF THE TWO IS SAFE and
-- the object survives both. Ask the catalogue.
do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_segment_spine';
  if k = 'v' then execute 'drop view market.security_segment_spine cascade';
  elsif k = 'm' then execute 'drop materialized view market.security_segment_spine cascade';
  end if;
end $$;

-- BUILT WITHOUT PARALLEL WORKERS, AND THAT IS NOT A TUNING CHOICE — IT IS WHAT MAKES THE DEPLOY
-- SURVIVE. A parallel worker allocates its shared memory in the container's `/dev/shm`, which is
-- Docker's default **64 MB** here and is not set anywhere in the stack. This build fitted inside it
-- until the segment backlog grew, and then on 2026-09-05 it did not:
--
--   ERROR: could not resize shared memory segment "/PostgreSQL.xxx" to 2097152 bytes:
--          No space left on device        CONTEXT: parallel worker
--
-- The failure is not survivable, because this migration DROPS the matview before recreating it:
-- the drop succeeded, the create died, and production was left with no `security_segment_spine` at
-- all — which migration 179 had just made `derive_segment_classification` depend on. Five later
-- migrations then failed with `relation ... does not exist`, and the deploy failed as a whole.
-- Every subsequent deploy would have failed the same way, because the drop happens every time.
--
-- Single-threaded the build needs no DSM segment at all, so it cannot fail this way regardless of
-- how large the segment table grows. Raising `/dev/shm` is the general fix and belongs in the
-- stack; this makes the migration independent of it either way.
set local max_parallel_workers_per_gather = 0;
set local max_parallel_maintenance_workers = 0;

create materialized view market.security_segment_spine as
  select * from market.security_segment_current;

-- REQUIRED FOR `refresh ... concurrently`, which is in turn required so a refresh does not take an
-- ACCESS EXCLUSIVE lock on the thing every aggregate reads. The grain is the view's own:
-- one row per (security, axis, member).
create unique index if not exists security_segment_spine_key_idx
  on market.security_segment_spine (security_id, axis, member_code);
create index if not exists security_segment_spine_concept_idx
  on market.security_segment_spine (concept_code) where concept_code is not null;
create index if not exists security_segment_spine_kind_idx
  on market.security_segment_spine (kind);

comment on materialized view market.security_segment_spine is
  'Every business line, materialised. Identical in content to security_segment_current (it is `select *` over it) and refreshed hourly by refresh_facets. Read this for anything that scans more than one security: the live view is 3.8 ms for one security and 6.1 s for all of them.';

-- ── The aggregates move onto it ───────────────────────────────────────────────────────────────
drop view if exists market.security_segment_geography;
create view market.security_segment_geography as
select
  c.security_id, c.member_code, c.country_iso2, c.member_label, c.axis,
  c.revenue, c.operating_income, c.revenue_share_pct,
  c.currency_code, c.period_ending, c.accession_number
from market.security_segment_spine c
where c.kind = 'geography'
  and c.member_label is not null;

comment on view market.security_segment_geography is
  'Revenue and operating income by the geography a filer discloses, for members whose meaning is published (ISO countries and standard regions) so nothing here required curation. A filer''s own extension for a region — bud:LatinAmericaWestMember — is deliberately absent: it needs a segment_member row before it can be named.';

-- `pending_segment_alias` is defined once, in migration 162 — see the note there. Defining a view
-- in several migrations forces the earliest to DROP (a `create or replace` cannot reorder or
-- rename columns), and that drop cascades to its dependents on every single deploy.

-- ── Refreshed on its OWN statement, because it will outgrow one ──────────────────────────────
-- A MATVIEW WITH NO SCHEDULED REFRESH IS A STALE VIEW NOBODY NOTICES — recorded when
-- `symbol_security` was added. The obvious home is `refresh_facets`, and it is the wrong one:
-- that function is invoked as a PostgREST RPC, which is a SINGLE STATEMENT under the role's
-- **8-second** timeout, and it already refreshes two spines. Measured here, `refresh ...
-- concurrently` on this spine is **7,242 ms** at 1.92M qualifying rows — so folding it in would
-- take the combined statement over the limit and kill the screener's spine along with it.
--
-- Hence a separate function, invoked as its own request with its own 8-second budget.
--
-- THE CEILING IS REAL AND REACHABLE, so it is reported rather than left to be discovered. 38.3% of
-- production's `security_segment` rows qualify for this spine (measured: 2,080 of 5,426 — annual,
-- partition 1), so 1.92M qualifying corresponds to roughly 5M facts, and the ~8M this pipeline is
-- heading for would need ~11 s. `duration_ms` comes back in the resource's report and lands in
-- `refresh_run`, which is what turns "it stopped working one Tuesday" into a line on a chart with
-- months of warning. When it does approach 8 s the escape is the one migration 142 already
-- established for SEC-paced work: give it a pg_cron job, which has no PostgREST timeout at all.
--
-- `create or replace function` PRESERVES THE EXISTING ACL, so this is drop-then-create; that is
-- what makes the revoke below load-bearing rather than decorative.
drop function if exists market.refresh_segment_spine();
create function market.refresh_segment_spine()
returns table (rows_refreshed bigint, duration_ms integer)
language plpgsql
security definer
set search_path = market, pg_catalog
-- SAME REASON AS THE BUILD ABOVE. A concurrent refresh runs the view's query, so it takes parallel
-- workers and their `/dev/shm` segments too — it measured 3,054 ms and succeeded, and would have
-- started failing on exactly the growth that broke the build. A silent failure here is worse than
-- the build's: `facets-refresh` records it and still returns ok, so the spine would simply stop
-- being rebuilt while every run reported success.
set max_parallel_workers_per_gather = 0
set max_parallel_maintenance_workers = 0
as $$
declare t0 timestamptz := clock_timestamp();
begin
  -- CONCURRENTLY so the refresh does not take an ACCESS EXCLUSIVE lock on the thing every
  -- aggregate reads. It needs the unique index above, and it cannot run inside a transaction
  -- block — which is why this is its own RPC rather than a step in a larger one.
  refresh materialized view concurrently market.security_segment_spine;
  return query
    -- `extract(milliseconds from ...)` ALREADY INCLUDES THE SECONDS field, so adding
    -- `1000 * extract(seconds ...)` double-counts it: a measured 6,454 ms call reported 12,436.
    -- A number that is not what its name says is the failure mode this schema is mostly about.
    select count(*)::bigint,
           (extract(epoch from clock_timestamp() - t0) * 1000)::integer
      from market.security_segment_spine;
end;
$$;

revoke execute on function market.refresh_segment_spine() from public;
grant execute on function market.refresh_segment_spine() to service_role;

-- ── The new backlogs must be classified, or backlog_drain cannot judge them ───────────────────
-- `market.backlog_negative_cache` is what lets `backlog_drain` tell a queue that drained by
-- WORKING from one that drained by MARKING — the 2026-08-13 signature, where `pending_industry`
-- reached zero while ~8,300 securities were negative-cached and the depth curve looked identical
-- to health. A backlog with no row here still gets a depth and a slope, and silently loses that
-- discrimination. These four arrived with the segment work and none had a row.
--
-- NOTE: six OTHER `pending_%` views are also unclassified (`pending_news`, `pending_insider`,
-- `pending_filings`, `pending_management`, `pending_eps_history`, `pending_fx_history`). They are
-- deliberately NOT guessed at here — naming the wrong column would assert a pairing that does not
-- hold, which is worse than the absence. Recorded in docs/data-ingestion.md as a known gap, along
-- with the CI guard that would stop the list growing again.
insert into market.backlog_negative_cache (backlog, missing_column, note) values
  ('pending_segments', null,
   'a CURSOR, not a negative cache: `security_filing.segments_parsed_at` records that we LOOKED, permanently, because a filed document is immutable. Re-reading is driven by segment_parser.version'),
  ('pending_filing_history', null,
   'a CURSOR (`filing_history_fetched_at`): filings keep arriving, so an absence is never permanent — the same reasoning as insider_fetched_at'),
  ('pending_wikidata', 'wikidata_missing_at', null),
  ('pending_segment_alias', null,
   'a DRIFT COUNTER, not a queue: segment_alias is EDITORIAL, so a non-zero value is expected for ever and the TREND is the signal. It grows when the parser reaches new filers and falls when somebody curates')
on conflict (backlog) do update
  set missing_column = excluded.missing_column, note = excluded.note;

-- ── Grants ────────────────────────────────────────────────────────────────────────────────────
-- `drop view` DISCARDS THE ACL, so every line here is load-bearing rather than tidy.
grant select on market.security_segment_spine, market.security_segment_geography
  to anon, authenticated, service_role;
-- `pending_segment_alias` is granted in 162, where it is now defined.

notify pgrst, 'reload schema';
