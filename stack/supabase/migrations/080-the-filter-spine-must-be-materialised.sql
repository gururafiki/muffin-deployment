-- THE FILTER SPINE TIMED OUT FOR ANON THE MOMENT TWO FILTERS WERE COMBINED, AND EVERY PROBE AS
-- SERVICE_ROLE SAID IT WAS HEALTHY.
--
-- Measured on the deployed node 2026-08-19, immediately after migration 77/78 landed:
--
--   as ANON (3s statement timeout)                              as service_role
--   security_facets, 1000 rows                    0.84s         0.61s
--   security_facets, country_iso2 = US            0.72s
--   security_facets, sector_id = financials       0.33s
--   security_facets, msci_tier = developed        0.58s
--   security_facets, msci_tier AND sector_id      **57014 canceling statement due to timeout**
--
-- Each predicate is survivable alone and the COMBINATION is not: with two filters the planner's
-- row estimate collapses to 1, it picks nested loops, and `security_current`'s per-row sector
-- lookup runs **59,076 times** behind a `Seq Scan on security` costed at 538,553. The pre-existing
-- `security_current` answers the same sector filter in 34ms — this is not that view being slow, it
-- is a wide join whose estimates fall apart under conjunction.
--
-- This is the SECOND time this exact shape has shipped (`fund_sector_weight`: 7.2s for service_role,
-- `57014` for anon, failing in the deployed app while every probe said fine). The rule from that
-- incident — TIME A VIEW AS ANON BEFORE BELIEVING IT WORKS — is what caught this one before the UI
-- was wired to it.
--
-- ── WHY MATERIALISE RATHER THAN TUNE THE PLAN ────────────────────────────────────────────────
--
-- The feature is ARBITRARY filter combinations. Tuning the one plan that failed leaves every other
-- conjunction to be discovered by a user, and each would fail the same silent way — a spinner, then
-- an error the app renders as "no data". Measured in a rolled-back transaction on the node:
--
--   build the whole matview + 4 indexes + analyze     ~1.9s
--   the query that TIMED OUT at 2993ms                 0.473ms
--   a harder 3-way filter (style + cap_band + tier)    0.607ms
--
-- Three orders of magnitude, and — the part that matters — BOUNDED for any combination, because an
-- index scan over 27,629 physical rows cannot degrade the way a seven-way join's estimates can.
--
-- It also removes a cost that would otherwise be paid on EVERY read: `security_style` computes a
-- `percent_rank()` over the whole universe, and a window function cannot be filtered early, so
-- asking for one security's facets computed the percentile for all 10,678.
--
-- Migration 78's header argues that STYLE should be a view and not a materialised table, and that
-- still holds — `security_style` remains a plain view. What is materialised here is the SPINE that
-- reads it. The distinction is real: the style definition stays a pure function of its inputs with
-- nothing to keep fresh, while the denormalised read model it feeds is refreshed on a cadence.
--
-- ── STALENESS IS THE PRICE, AND IT IS BOUNDED AND VISIBLE ────────────────────────────────────
--
-- Every column here is reference data written by ingest resources that run a few times a day, so a
-- refresh cadence matching them loses nothing a user could perceive. `refreshed_at` is stored so
-- the age is a fact the app can read rather than something to infer, and `market-verify` can fail
-- on a spine that has stopped refreshing — the failure mode this codebase keeps hitting is a
-- resource that silently stops, so the freshness has to be observable.
--
-- REFRESH ... CONCURRENTLY, which requires a UNIQUE index: without it the refresh takes an
-- ACCESS EXCLUSIVE lock and every read of the Markets tab blocks behind a 2-second rebuild.

-- DROP WHICHEVER FORM EXISTS. `IF EXISTS` does NOT protect against a relkind mismatch: measured
-- 2026-08-19, `drop view if exists` on a materialized view raises `"x" is not a view`, and
-- `drop materialized view if exists` on a plain view raises `"x" is not a materialized view` — so
-- neither ordering of the two statements is safe, and the object survives both. Migration 80 turns
-- this relation into a matview, so on every deploy after the first it arrives here as one.
do $$
declare k "char";
begin
  select c.relkind into k from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_facets';
  if k = 'm' then
    execute 'drop materialized view if exists market.security_facets cascade';
  elsif k is not null then
    execute 'drop view if exists market.security_facets cascade';
  end if;
end $$;

create materialized view market.security_facets as
with country_lens as (
  select
    iso2,
    max(group_id) filter (where scheme_id = 'msci'       and lens = 'tier')   as msci_tier,
    max(group_id) filter (where scheme_id = 'msci'       and lens = 'region') as msci_region,
    max(group_id) filter (where scheme_id = 'ftse'       and lens = 'tier')   as ftse_tier,
    max(group_id) filter (where scheme_id = 'ftse'       and lens = 'region') as ftse_region,
    max(group_id) filter (where scheme_id = 'world-bank' and lens = 'tier')   as income_group,
    max(group_id) filter (where scheme_id = 'world-bank' and lens = 'region') as wb_region
  from market.classification_members
  group by iso2
)
select
  sc.security_id,
  sc.symbol,
  sc.name,
  sc.security_type_code,
  sc.sector_id,
  sc.industry,
  sc.industry_code,
  sc.country_iso2,
  sc.country_name,
  c.region_id                     as app_region_id,
  c.market                        as country_market,
  cl.msci_tier,
  cl.msci_region,
  cl.ftse_tier,
  cl.ftse_region,
  cl.income_group,
  cl.wb_region,
  mc.market_cap_usd,
  sc.market_cap                   as market_cap_native,
  case
    when mc.market_cap_usd is null      then null
    when mc.market_cap_usd >= 10e9      then 'large'
    when mc.market_cap_usd >=  2e9      then 'mid'
    when mc.market_cap_usd >      0     then 'small'
  end                             as cap_band,
  cur.currency_code,
  cur.source                      as currency_source,
  s.maturity_date,
  s.coupon_rate,
  s.coupon_kind_code,
  s.in_default,
  sc.is_tradeable,
  sty.style,
  sty.style_source,
  sty.style_confidence,
  sty.value_score,
  sty.cohort                      as style_cohort,
  -- WHEN THIS SNAPSHOT WAS TAKEN. `now()` is evaluated once per refresh, so every row of a given
  -- refresh carries the same timestamp and the app can show the spine's age instead of implying
  -- the data is live.
  now()                           as refreshed_at
from market.security_current sc
join market.security s          on s.security_id = sc.security_id
left join market.countries c    on c.iso2 = sc.country_iso2
left join country_lens cl       on cl.iso2 = sc.country_iso2
left join market.security_market_cap_usd mc on mc.security_id = sc.security_id
left join market.security_currency cur      on cur.security_id = sc.security_id
left join market.security_style sty         on sty.security_id = sc.security_id;

-- REQUIRED for `refresh materialized view concurrently`. Also the join key `aggregate_performance`
-- and every per-security lookup uses.
create unique index if not exists security_facets_pk on market.security_facets (security_id);

-- One index per dimension a filter chip can set. The conjunction that failed is served by any one
-- of them plus a cheap recheck; there is no need to guess which pairs a user will combine, which
-- is precisely the property the un-materialised view did not have.
create index if not exists security_facets_sector_idx    on market.security_facets (sector_id);
create index if not exists security_facets_industry_idx  on market.security_facets (industry);
create index if not exists security_facets_ind_code_idx   on market.security_facets (industry_code);
create index if not exists security_facets_country_idx   on market.security_facets (country_iso2);
create index if not exists security_facets_msci_tier_idx on market.security_facets (msci_tier);
create index if not exists security_facets_msci_reg_idx  on market.security_facets (msci_region);
create index if not exists security_facets_ftse_tier_idx on market.security_facets (ftse_tier);
create index if not exists security_facets_income_idx    on market.security_facets (income_group);
create index if not exists security_facets_wb_region_idx on market.security_facets (wb_region);
create index if not exists security_facets_app_reg_idx   on market.security_facets (app_region_id);
create index if not exists security_facets_cap_band_idx  on market.security_facets (cap_band);
create index if not exists security_facets_style_idx     on market.security_facets (style);
create index if not exists security_facets_type_idx      on market.security_facets (security_type_code);
create index if not exists security_facets_symbol_idx    on market.security_facets (symbol);
create index if not exists security_facets_cap_usd_idx   on market.security_facets (market_cap_usd);

analyze market.security_facets;

comment on materialized view market.security_facets is
  'The filter spine: every dimension a list can be filtered by, on one row per security. MATERIALISED because the un-materialised view timed out for anon (57014) the moment two filters were combined — measured 2026-08-19, msci_tier AND sector_id took 2993ms against a 3s statement timeout, while the same query answers in 0.47ms from here. Refreshed by the `facets-refresh` resource; `refreshed_at` carries the snapshot age.';

grant select on market.security_facets to anon, authenticated, service_role;

-- ── the refresh ──────────────────────────────────────────────────────────────────────────────
--
-- SECURITY DEFINER because `refresh materialized view` requires ownership, which service_role does
-- not have and should not be given. Revoked from PUBLIC first: a definer function left with the
-- default PUBLIC grant is executable by anon, and this one rebuilds 27,629 rows — a free way for
-- anyone holding the public anon key to load the database. (`create or replace function` preserves
-- the existing ACL, so the drop is what makes these grants authoritative on a re-run — see
-- migration 79.)
drop function if exists market.refresh_facets();

create function market.refresh_facets()
returns table (rows_refreshed bigint, refreshed_at timestamptz)
language plpgsql
security definer
set search_path = market, pg_catalog
as $$
begin
  -- CONCURRENTLY so readers are not blocked for the ~2s rebuild. It cannot run inside a
  -- transaction block, which is why this is a function called by a resource rather than a
  -- statement in a migration that applies `--single-transaction`.
  refresh materialized view concurrently market.security_facets;
  return query
    select count(*)::bigint, max(f.refreshed_at) from market.security_facets f;
end;
$$;

revoke execute on function market.refresh_facets() from public;
grant execute on function market.refresh_facets() to service_role;

notify pgrst, 'reload schema';
