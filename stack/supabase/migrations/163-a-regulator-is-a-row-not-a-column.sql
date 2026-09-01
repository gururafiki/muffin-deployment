-- Which regulator can serve a security's disclosures — IDEMPOTENT.
--
-- Migration 160 added a `sec_filer` dimension so segment coverage could be measured against a
-- population that can actually have segments. It answers "does this security have a CIK", which is
-- coextensive with "can it have segments" ONLY while SEC is the sole source — and Korea (DART) is
-- already measured viable through the same parser and the same axes. The two diverge the moment it
-- ships: Korean companies would have segments while reading `sec_filer = no`, so the dimension
-- would be measuring the wrong thing while looking correct.
--
-- The gap is not marginal. Measured 2026-08-29 across the equity universe:
--
--     China   2,325 equities,  14 SEC-reachable      Japan    1,368,  103
--     Europe  1,438 (20 countries), 260              India      645,    0
--     Korea     466,   0  (DART proven)              Taiwan     535,    2
--
-- CAPABILITY IS NOT A PROPERTY OF COUNTRY, which is the trap this models around. TSMC is Taiwanese
-- and files with SEC; 787 non-US securities file a 20-F or 40-F. So "country -> source" is wrong,
-- and capability is instead "holds a registration with a regulator" — exactly what `cik` records,
-- generalised.
--
-- `market.segment_axis` is the precedent for the whole shape: the axis name is DATA, so Korea cost
-- ONE ROW (migration 155) rather than a parser branch. Same here — a new regulator is rows.

-- ── The regulators ────────────────────────────────────────────────────────────────────────────
create table if not exists market.disclosure_source (
  code              text primary key,
  name              text not null,
  -- What the regulator calls the identifier it addresses a filer by. Displayed, and it stops the
  -- next reader assuming every filer id is a CIK.
  identifier_label  text not null,
  -- ENABLED IS THE SAFETY CATCH, and false is the correct default for anything unbuilt. A source
  -- with no resource behind it must not make securities read as `resolvable` — that would report
  -- an addressable backlog nothing can address. Same reasoning as `exchange.promotion_enabled`,
  -- which is false for every venue so a deploy can never start spending on its own.
  enabled           boolean not null default false,
  priority          integer not null default 0,
  note              text
);

comment on table market.disclosure_source is
  'Regulators that publish machine-readable disclosures. A control table: adding one is a row plus a resource, never a schema change. `enabled` is false until a resource exists, because an enabled source with no fetcher reports an addressable backlog that nothing can address.';

insert into market.disclosure_source (code, name, identifier_label, enabled, priority, note) values
  ('sec',    'SEC EDGAR',  'CIK',        true,  100,
   'Registration-driven rather than jurisdictional: 787 non-US securities file a 20-F or 40-F, so SEC deliberately has NO rows in disclosure_coverage.'),
  ('dart',   'DART (Korea)', 'corp_code', false,  90,
   'Measured viable 2026-08-29: a full 7.1 MB instance carrying ifrs-full:ProductsAndServicesAxis / SegmentsAxis / GeographicalAreasAxis — the same axes the parser already handles for Diageo. SK Gas reconciles exactly to 7,050,068,258,000 KRW. Enabled once security-kr-segments exists.'),
  ('edinet', 'EDINET (Japan)', 'edinet_code', false, 80,
   'Measured NOT viable 2026-08-29: Nintendo FY2026 carries 8 distinct dimensions and ZERO segment axes. The segment note is jpcrp_cor:NotesSegmentInformationEtc...TextBlock — escaped HTML in a text block. Kept as a row so the finding is not re-derived.'),
  ('esef',   'ESEF (EU)',  'lei',         false,  70,
   'Measured NOT viable 2026-08-29: ASML, Nokia, Novo Nordisk and TotalEnergies FY2025 carry 431-872 facts and ZERO segment axes. ESEF mandates detailed tagging of the PRIMARY STATEMENTS only; the IFRS 8 note is block-tagged as text.')
on conflict (code) do update
  set name = excluded.name, identifier_label = excluded.identifier_label,
      priority = excluded.priority, note = excluded.note;
-- `enabled` is deliberately NOT in the DO UPDATE list: an operator who enables a source in Studio
-- must not have the next deploy switch it back off. Same rule as `tracked_fund`, where memberships
-- upsert `do nothing` so a redeploy cannot revert a curation.

-- ── Which securities a regulator can address ──────────────────────────────────────────────────
create table if not exists market.security_filer (
  security_id  uuid not null references market.security (security_id) on delete cascade,
  source_code  text not null references market.disclosure_source (code),
  filer_id     text not null,
  as_of        timestamptz not null default now(),
  primary key (security_id, source_code)
);

-- `filer_id` IS DELIBERATELY NOT UNIQUE. GOOG and GOOGL are two securities sharing one CIK, which
-- is precisely why `security.cik` is a column rather than a row in `security_identifier`, whose
-- primary key is (kind_code, value) and would collapse them. An index for the reverse lookup, not
-- a constraint.
create index if not exists security_filer_lookup_idx on market.security_filer (source_code, filer_id);

comment on table market.security_filer is
  'The identifier each regulator addresses a security by — a CIK for SEC, a corp_code for DART. filer_id is NOT unique: share classes share a filer (GOOG and GOOGL are one CIK), which is why security.cik could never live in security_identifier.';

-- Backfilled from the column that has always held this, and re-run every deploy so the two cannot
-- drift while both exist. `security.cik` stays for now: migrating its readers is Phase 3 work and
-- doing it in the same change as the model would make a failure impossible to attribute.
insert into market.security_filer (security_id, source_code, filer_id)
select s.security_id, 'sec', s.cik::text
from market.security s
where s.cik is not null
on conflict (security_id, source_code) do update set filer_id = excluded.filer_id;

-- AN INVARIANT EVERY WRITER MUST REMEMBER IS A TRIGGER. `sec-cik-map` writes `security.cik` at
-- runtime, so a company that lists tomorrow gets a CIK and — without this — no `security_filer`
-- row until the next deploy re-runs the backfill above. Its capability would read `none` while the
-- data to fetch its filings was sitting in the next column. "Every writer also inserts a filer row"
-- is one call site today and the next resource forgets, which is exactly why `derived_at` became a
-- trigger rather than a rule in three upserts.
create or replace function market.sync_sec_filer() returns trigger
language plpgsql
security definer
set search_path = market, pg_catalog
as $$
begin
  if new.cik is not null then
    insert into market.security_filer (security_id, source_code, filer_id)
         values (new.security_id, 'sec', new.cik::text)
    on conflict (security_id, source_code) do update set filer_id = excluded.filer_id;
  else
    -- A CLEARED CIK MUST RETRACT. Leaving the row would keep the security reading `held` against a
    -- registration we no longer believe in, and an upsert cannot retract.
    delete from market.security_filer
     where security_id = new.security_id and source_code = 'sec';
  end if;
  return new;
end $$;

drop trigger if exists security_cik_to_filer on market.security;
create trigger security_cik_to_filer
  after insert or update of cik on market.security
  for each row execute function market.sync_sec_filer();

-- ── Which jurisdictions a regulator covers ────────────────────────────────────────────────────
create table if not exists market.disclosure_coverage (
  source_code   text not null references market.disclosure_source (code),
  country_iso2  text not null references market.countries (iso2),
  primary key (source_code, country_iso2)
);

comment on table market.disclosure_coverage is
  'Which jurisdictions a regulator serves, for securities whose filer id has not been resolved yet. SEC has NO rows on purpose — it is registration-driven and serves any country that registers with it, so a country row would wrongly imply every US-domiciled security is reachable and every foreign one is not.';

insert into market.disclosure_coverage (source_code, country_iso2) values
  ('dart',   'KR'),
  ('edinet', 'JP')
on conflict do nothing;

-- ── Which forms carry audited segment disclosure ──────────────────────────────────────────────
-- `pending_segments` hardcodes `report_type in ('10-K','10-Q','20-F','40-F')`. That list is SEC's
-- vocabulary, and DART's is different — so it becomes data for the same reason `segment_axis` did.
create table if not exists market.filing_form (
  source_code      text not null references market.disclosure_source (code),
  form_code        text not null,
  is_annual        boolean not null,
  carries_segments boolean not null default true,
  primary key (source_code, form_code)
);

comment on table market.filing_form is
  'Forms that carry audited accounts, per regulator. A 6-K or 8-K is an EVENT, not accounts, and a foreign private issuer files 20-F/40-F INSTEAD OF 10-K/10-Q rather than as well — so a rule classifying filings must know both vocabularies or every foreign annual report is labelled an event.';

insert into market.filing_form (source_code, form_code, is_annual, carries_segments) values
  ('sec', '10-K', true,  true),
  ('sec', '10-Q', false, true),
  ('sec', '20-F', true,  true),
  ('sec', '40-F', true,  true)
on conflict (source_code, form_code) do update
  set is_annual = excluded.is_annual, carries_segments = excluded.carries_segments;

-- ── Capability, resolved ──────────────────────────────────────────────────────────────────────
-- THREE STATES, NOT TWO, and the middle one is the point. "Its jurisdiction has a working source
-- but we have not resolved the filer id" is the addressable backlog, and nothing today can see it:
-- a security in that state is indistinguishable from a Cayman shell that will never have segments.
-- DROP ITS DEPENDENTS FIRST, DISCOVERED RATHER THAN LISTED. Migration 164 builds
-- `coverage_current` on this view, and every migration re-runs in order on every deploy — so on
-- the SECOND pass this drop meets an object that did not exist on the first and fails the whole
-- deploy. A named list cannot work here because the dependent belongs to a LATER file; migration
-- 157 shipped exactly this bug and it was only caught because a mutation harness could not apply a
-- single mutation.
do $$
declare v record;
begin
  for v in
    select dv.relname, dv.relkind
    from pg_depend d
    join pg_rewrite r   on r.oid = d.objid
    join pg_class dv    on dv.oid = r.ev_class
    join pg_class src   on src.oid = d.refobjid
    join pg_namespace n on n.oid = src.relnamespace
    where n.nspname = 'market'
      and src.relname = 'security_disclosure'
      and dv.relname <> 'security_disclosure'
      -- `IF EXISTS` does not protect against a relkind mismatch: `drop view` on a matview raises
      -- `is not a view`, and the converse also raises, so neither ordering of the two is safe.
      and dv.relkind in ('v', 'm')
  loop
    if v.relkind = 'm' then
      execute format('drop materialized view if exists market.%I cascade', v.relname);
    else
      execute format('drop view if exists market.%I cascade', v.relname);
    end if;
  end loop;
end $$;

drop view if exists market.security_disclosure;
create view market.security_disclosure as
-- MATERIALIZED, AND THAT IS LOAD-BEARING. PostgreSQL 12+ inlines a CTE by default, and inlined
-- these are evaluated PER SECURITY: the first version used two LATERALs and measured 204 ms alone
-- over 27,600 securities — two nested loops at 27,600 iterations each — which took
-- `coverage_current` from 228 ms to 596 ms. `sample_coverage` is ONE PostgREST statement under the
-- role's 8-second timeout, and migration 140 exists because a single added facet took this view to
-- 7.9 s, so a 2.6x regression is not affordable.
--
-- Materialised, each is evaluated ONCE over a small set — `held` is one row per security holding a
-- filer id (3,500 today), `by_country` is one row per covered country (2) — and both hash-join.
with enabled_source as materialized (
  select code, priority from market.disclosure_source where enabled
),
held as materialized (
  select distinct on (f.security_id) f.security_id, f.source_code, f.filer_id
  from market.security_filer f
  join enabled_source d on d.code = f.source_code
  order by f.security_id, d.priority desc, f.source_code
),
by_country as materialized (
  select distinct on (c.country_iso2) c.country_iso2, c.source_code
  from market.disclosure_coverage c
  join enabled_source d on d.code = c.source_code
  order by c.country_iso2, d.priority desc, c.source_code
)
select
  s.security_id,
  -- The best source that can actually serve this security today.
  coalesce(h.source_code, bc.source_code)                            as segment_source,
  (h.source_code is not null)                                        as filer_id_held,
  case
    when h.source_code  is not null then 'held'
    when bc.source_code is not null then 'resolvable'
    else 'none'
  end                                                                 as capability,
  h.filer_id
from market.security s
left join held h on h.security_id = s.security_id
-- The EFFECTIVE country, coalesce(provider, filed) — the same value `security_current` answers
-- with, so two views cannot disagree about where a company is.
left join by_country bc on bc.country_iso2 = coalesce(s.provider_country_iso2, s.country_iso2);

comment on view market.security_disclosure is
  'Which regulator can serve a security, in three states: `held` (a filer id is stored, fetchable now), `resolvable` (its jurisdiction has an ENABLED source but the id is unresolved — the addressable backlog) and `none` (no source covers it, so an absence is permanent). Country is the EFFECTIVE one, coalesce(provider, filed), the same value security_current answers with.';

grant select on market.disclosure_source, market.security_filer, market.disclosure_coverage,
                market.filing_form, market.security_disclosure
  to anon, authenticated, service_role;
grant insert, update, delete on market.disclosure_source, market.security_filer,
                                market.disclosure_coverage, market.filing_form
  to service_role;

alter table market.disclosure_source   enable row level security;
alter table market.security_filer      enable row level security;
alter table market.disclosure_coverage enable row level security;
alter table market.filing_form         enable row level security;
drop policy if exists disclosure_source_read   on market.disclosure_source;
drop policy if exists security_filer_read      on market.security_filer;
drop policy if exists disclosure_coverage_read on market.disclosure_coverage;
drop policy if exists filing_form_read         on market.filing_form;
create policy disclosure_source_read   on market.disclosure_source   for select using (true);
create policy security_filer_read      on market.security_filer      for select using (true);
create policy disclosure_coverage_read on market.disclosure_coverage for select using (true);
create policy filing_form_read         on market.filing_form         for select using (true);

notify pgrst, 'reload schema';
