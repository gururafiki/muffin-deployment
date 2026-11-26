-- Each regulator has its own segment parser version, and segment total concepts are scoped to a
-- regulator (Phase 6c step 1a, decision 4 of docs/specs/2026-11-26-more-segment-sources.md).
--
-- WHY. `market.segment_parser` held ONE version for every regulator. A reader fix for one regulator
-- therefore either re-queued every regulator's history (a bump makes ~148,000 SEC filings due, most
-- of them no longer in raw) or needed a hand-written one-shot re-queue, which is what migrations
-- 20261122..20261126 each did. Phase 6c adds three more readers (EDINET, ESEF, China's segment
-- note), so the version becomes per regulator: a fix to one reader is a bump of its own row.
--
-- EXPAND ONLY. The `singleton` column and its check stay (dropped later:
-- docs/deferred/2026-11-26-drop-the-segment-parser-singleton.md). Every regulator's row starts at
-- today's version (20 on 2026-11-26), so `max(version)` (what the muffin-ingest queues read until
-- step 1b rolls) still means what it did: this deploy re-queues nothing and can land before the roll.
--
-- THE ROWS ARE DERIVED FROM `disclosure_source.enabled`, not typed out: every enabled regulator
-- gets one, and the guard test asserts it stays that way, so enabling EDINET or ESEF later without
-- its parser row fails CI rather than leaving a queue with no version to compare against.
--
-- `market.segment_total_concept` holds the concepts a regulator's segment parser may take as a
-- split's total, beside the global `xbrl_concept`. That table is global on purpose: SEC, DART and
-- NSE segment parsing read it, and so does the SEC statement lane (`sec_facts.CONCEPTS_SQL`), so a
-- concept added there for one regulator changes the others. Measured 2026-11-26:
-- `RevenueFromSaleOfGoods` is a component of revenue in DART instances, and Japanese `NetSales` would
-- match extensions in 10-Ks. The table ships empty; step 2 adds SEC's rows and step 5 EDINET's.
--
-- Idempotent, so the replay can restore it after each mutation.

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'market' and table_name = 'segment_parser'
                    and column_name = 'regulator') then
    alter table market.segment_parser add column regulator text;
    -- The one row there is today is SEC's in all but name: every lane compares against it.
    update market.segment_parser set regulator = 'sec';
    alter table market.segment_parser alter column regulator set not null;
  end if;
end $$;

alter table market.segment_parser drop constraint if exists segment_parser_pkey;
alter table market.segment_parser add constraint segment_parser_pkey primary key (regulator);
alter table market.segment_parser drop constraint if exists segment_parser_regulator_fkey;
alter table market.segment_parser add constraint segment_parser_regulator_fkey
  foreign key (regulator) references market.disclosure_source (code);

insert into market.segment_parser (regulator, version)
select d.code, (select max(p.version) from market.segment_parser p)
  from market.disclosure_source d
 where d.enabled
on conflict (regulator) do nothing;

comment on table market.segment_parser is
  'One row per regulator. Bumping a regulator''s `version` re-queues that regulator''s filings for '
  'segment parsing, and no other''s. Every enabled `disclosure_source` has a row '
  '(tests/each-regulator-has-its-own-parser-version.sql). Bump it in a migration guarded by '
  '`market.one_shot`, never unguarded.';
comment on column market.segment_parser.regulator is
  'The `disclosure_source` whose filings this version governs. A filing is due when its '
  '`segments_parser_version` is below its regulator''s row.';
comment on column market.segment_parser.singleton is
  'Retired by the per-regulator key (2026-11-26); dropped by a later contract migration.';

create table if not exists market.segment_total_concept (
  regulator text not null references market.disclosure_source (code),
  metric_code text not null references market.metric (code),
  concept text not null,
  priority integer not null default 100,
  note text,
  primary key (regulator, metric_code, concept)
);

comment on table market.segment_total_concept is
  'Concepts a regulator''s segment parser may take as a split''s total, in addition to the global '
  '`xbrl_concept`. Scoped because `xbrl_concept` is read by every regulator''s segment parser and by '
  'the SEC statement lane: `RevenueFromSaleOfGoods` is a component of revenue in DART instances. '
  '`concept` is the local name, as in `xbrl_concept`.';

alter table market.segment_total_concept enable row level security;
drop policy if exists segment_total_concept_read on market.segment_total_concept;
create policy segment_total_concept_read on market.segment_total_concept for select using (true);
grant select on market.segment_total_concept to anon, authenticated, ingest_rw;
grant select, insert, update, delete on market.segment_total_concept to service_role;
-- A control table the worker reads: the worker may not rewrite its own instructions, and the
-- schema's default privileges grant `ingest_rw` DML on every new `market` table.
revoke insert, update, delete, truncate on market.segment_total_concept from ingest_rw;
