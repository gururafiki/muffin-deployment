-- A CROWD CAN NAME MORE THAN ONE INDUSTRY, WHICH IS THE ONE THING NO PROVIDER HERE DOES.
--
-- Every classification this schema holds is single-valued per source: yfinance gives one sector and
-- one industry, a filing gives one, SEC gives one SIC. Measured 2026-08-28, that is why
-- `security_taxonomy` — modelled many-to-many since migration 10 — held exactly `{1: 7754}` at
-- level 2. The multiplicity was designed and never populated.
--
-- Wikidata's `industry (P452)` is genuinely multi-valued and joins on the ISIN this pipeline
-- already holds for nearly everything (P946). Measured live, 12 ISINs in ONE request taking
-- **0.78 seconds**:
--
--     Amazon      retail | web service | e-commerce | web hosting service
--     Apple       digital distribution | software development | software industry | ... (7)
--     Unilever    food industry | personal care product | fast-moving consumer goods | ... (9)
--     Tesla       automotive industry | solar industry | battery industry
--
-- 11 of 12 matched; TotalEnergies did not, which is the ordinary case and is why there is a
-- negative cache.
--
-- PRIORITY 30 — THE LOWEST OF ANY SOURCE HERE, and that is the honest placement. It is
-- crowd-sourced, its granularity is inconsistent (Nestlé is simply "food industry" while Apple has
-- seven), and it carries occasional noise: Microsoft's list includes "International Standard
-- Industrial Classification of All Economic Activities", which is a reference work rather than an
-- industry. So it must never win `security_current.sector_id`, and it is useful for exactly one
-- thing — telling you the other things a company also is.

insert into market.taxonomy (taxonomy_id, name, description) values
  ('wikidata', 'Wikidata industries',
   'Crowd-sourced, MULTI-VALUED industry tags (P452), joined on ISIN. Inconsistent granularity by nature; the lowest-priority source here.')
on conflict (taxonomy_id) do update
  set name = excluded.name, description = excluded.description;

-- NODES ARE CREATED ON DISCOVERY, not seeded. Wikidata's industry vocabulary is open — there is no
-- fixed list to seed and no authority publishing one, so the resource inserts a node the first time
-- it sees a label. That is the opposite of the SIC tree in migration 151, where SEC publishes a
-- closed list of 444 and inventing entries would be authoring reference data from memory.

-- ── The negative cache ────────────────────────────────────────────────────────────────────────
--
-- Most securities are simply not in Wikidata, and a backlog defined as "has an ISIN, has no
-- wikidata row" re-asks for them for ever — the defect this file has recorded five separate times
-- (`figi_missing_at`, `profile_missing_at`, `local_symbol_missing_at`, `performance_missing_at`,
-- `prices_missing_at`). Thirty days, not never: an entry can be created.
alter table market.security add column if not exists wikidata_missing_at timestamptz;

comment on column market.security.wikidata_missing_at is
  'Wikidata has no industry tags for this security''s ISIN. Re-asked after 30 days, because an entry can be created.';

-- CLASSIFIED, or `tests/negative-caches-are-classified.sql` fails CI.
--
-- `symbol_cache_classification` is a VIEW, so this is not an insert — it is the WHOLE list,
-- re-declared. Copied from migration 136's definition (the current one) rather than from the file
-- that introduced it: migration 106 rebuilt this view from migration 050's nine entries and
-- silently deleted the eight added in between, which would have stopped a corrected symbol
-- clearing any of them, invisibly.
--
-- ISIN-keyed, NOT symbol-keyed: a corrected provider symbol says nothing about a Wikidata entity,
-- so `clear_symbol_caches` must NOT clear it — the same reasoning as `figi_missing_at`.
drop view if exists market.symbol_cache_classification;
create view market.symbol_cache_classification as
select * from (values
  ('industry_missing_at',          true,  'yfinance profile fetched by symbol'),
  ('profile_missing_at',           true,  'yfinance profile fetched by symbol'),
  ('performance_missing_at',       true,  'historical bars fetched by symbol'),
  ('fundamentals_missing_at',      true,  'metrics fetched by symbol'),
  ('statements_missing_at',        true,  'statements fetched by symbol'),
  ('prices_missing_at',            true,  'daily bars fetched by symbol'),
  ('quarters_missing_at',          true,  'quarterly statements fetched by the PRICED symbol'),
  ('provider_country_missing_at',  true,  'yfinance profile fetched by symbol'),
  ('corporate_actions_missing_at', true,  'Tiingo EOD fetched by the US ticker'),
  ('dividends_missing_at',         true,  'yfinance dividends fetched by the PRICED symbol'),
  ('price_history_missing_at',     true,  'weekly history fetched by the PRICED symbol'),
  ('daily_history_missing_at',     true,  'deep daily history fetched by the PRICED symbol'),
  ('share_stats_missing_at',       true,  'share statistics fetched by the PRICED symbol'),
  ('estimates_missing_at',         true,  'analyst consensus fetched by the PRICED symbol'),
  ('profile_detail_missing_at',    true,  'yfinance profile fetched by symbol'),
  ('figi_missing_at',              false, 'OpenFIGI asked for the ISIN, not the symbol'),
  ('local_symbol_missing_at',      false, 'keyed on ISIN/FIGI, not the symbol'),
  ('yahoo_symbol_missing_at',      false, 'the resolver''s own flag — clearing it here would loop'),
  ('statement_currency_missing_at', false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'),
  ('xbrl_missing_at',              false, 'company facts are asked for by CIK; a new provider symbol says nothing about the filer'),
  ('wikidata_missing_at',          false, 'Wikidata is asked for by ISIN; a corrected provider symbol says nothing about a Wikidata entity, and clearing it would re-ask a public endpoint for an answer already held')
) as t(column_name, symbol_keyed, reason);

-- RE-GRANTED, because `drop view` DISCARDS THE ACL. Caught by
-- `tests/every-table-is-reachable.sql` the moment the view was re-declared: a view that exists,
-- returns the right rows and is unreadable by the role that needs it is exactly the shape of the
-- `security_price` incident, where migration 42 granted the two views and forgot the table.
grant select on market.symbol_cache_classification to anon, authenticated, service_role;

-- ── The backlog ───────────────────────────────────────────────────────────────────────────────
drop view if exists market.pending_wikidata;
create view market.pending_wikidata as
select
  s.security_id,
  i.value as isin,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier i
  on i.security_id = s.security_id and i.kind_code = 'isin'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and (s.wikidata_missing_at is null
       or s.wikidata_missing_at < now() - interval '30 days')
  -- AN ANTI-JOIN OVER THE ENTITY, null-checking the FIRST left-joined table. `pending_industry`
  -- once asked this question through a second table reached by an unrestricted join, so a
  -- security's own rows survived the filter and it was queued for ever while reporting progress.
  and not exists (
    select 1 from market.security_taxonomy st
    where st.security_id = s.security_id and st.source_code = 'wikidata'
  )
group by s.security_id, i.value
order by best_weight desc, s.security_id;

comment on view market.pending_wikidata is
  'Equities with an ISIN and no Wikidata industry tags yet. Ordered by fund weight so the largest holdings resolve first.';

grant select on market.pending_wikidata to service_role;

notify pgrst, 'reload schema';

-- ── Scheduling ────────────────────────────────────────────────────────────────────────────────
--
-- IN THE ROTATION, unlike the two SEC resources. Migration 142 took those out because they have a
-- 30,000-item backlog and SEC's budget is uncontended; this has neither property. The Wikidata
-- endpoint is public, shared and politeness-limited rather than quota'd, so a turn every ~190
-- minutes is the right cadence for it — and its backlog is bounded by the number of equities with
-- an ISIN, most of which are answered or negative-cached on the first pass.
insert into market.cron_resource (position, resource) values
  (400, 'security-wikidata-industries')
on conflict (position) do update set resource = excluded.resource;

notify pgrst, 'reload schema';
