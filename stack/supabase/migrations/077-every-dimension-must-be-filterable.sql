-- REGION, ECONOMY TIER AND INCOME GROUP HAVE BEEN SEEDED ALL ALONG AND NOTHING COULD FILTER BY THEM.
--
-- `market.classification_members` holds six full country lenses — measured 2026-08-18:
--
--   msci/region        67 countries   na, dev-europe, dev-pacific, em-asia, em-emea, em-latam, frontier
--   msci/tier          67            developed, emerging, frontier
--   ftse/region        66            (same seven regions)
--   ftse/tier          65            developed, advanced-emerging, secondary-emerging, frontier
--   world-bank/region 221            seven geographic regions
--   world-bank/tier   181            high, upper-middle, lower-middle, low   <- income group
--
-- …and **no view joined any of it to a security**, so a filter like "developed-market industrials"
-- or "upper-middle-income financials" was impossible despite the data being complete. This one view
-- turns all six into filterable columns without a single new fetch.
--
-- Two more things were in the same state — present, correct, and unreachable from a list:
--
--   * `security_market_cap_usd` (migration 73) — the ONLY comparable cap, since 71% of caps are
--     non-USD. Nothing read it. Cap BANDS were therefore impossible: banding native `market_cap`
--     would put a ₩1,802tn Korean company and a $1.8tn American one in wildly wrong buckets.
--   * bond `maturity_date` / `coupon_rate` / `in_default` (migration 71) — on `security`, on no
--     serving view. Bonds are 15,159 of 27,629 securities and could not be filtered at all.
--
-- ── WHY THE PIVOT IS EXPLICIT ────────────────────────────────────────────────────────────────
--
-- Six named columns rather than a generic (scheme, lens, group) long form. The long form is
-- tempting and wrong here: every caller would have to re-pivot it, a filter would need a subquery
-- per dimension instead of a predicate, and PostgREST cannot express "region = X AND tier = Y"
-- against it without two embedded joins. Named columns are greppable, indexable, and one `.eq()`
-- each. Adding a seventh lens is one more column in one place.
--
-- ── CAP BANDS ─────────────────────────────────────────────────────────────────────────────────
--
-- large >= $10bn · mid $2-10bn · small < $2bn, on the USD figure. Measured split across the
-- universe: 2,213 / 3,896 / 5,363. The thresholds are conventional rather than derived, and are
-- stated here so they can be argued with; `market_cap_usd` being NULL yields a NULL band, never a
-- guess — a security whose currency has no FX rate is unbanded, not "small".

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

create view market.security_facets as
with country_lens as (
  -- One row per country carrying all six lenses. Pivoted with filtered aggregates rather than six
  -- left joins: one pass over a 657-row table instead of six.
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
  -- The EFFECTIVE country, as every view has used since migration 56.
  sc.country_iso2,
  sc.country_name,
  -- The app's own six regions (countries.region_id), distinct from the scheme regions below.
  c.region_id                     as app_region_id,
  -- MSCI-derived tier, denormalised onto countries by migration 19. Kept beside `msci_tier` from
  -- the lens because they are the same fact by two routes and a disagreement is worth being able
  -- to see rather than hiding behind a coalesce.
  c.market                        as country_market,
  cl.msci_tier,
  cl.msci_region,
  cl.ftse_tier,
  cl.ftse_region,
  cl.income_group,
  cl.wb_region,
  -- COMPARABLE cap, and the band derived from it. Native cap is deliberately NOT banded.
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
  -- Bonds become filterable for the first time.
  s.maturity_date,
  s.coupon_rate,
  s.coupon_kind_code,
  s.in_default,
  sc.is_tradeable
from market.security_current sc
join market.security s          on s.security_id = sc.security_id
left join market.countries c    on c.iso2 = sc.country_iso2
left join country_lens cl       on cl.iso2 = sc.country_iso2
left join market.security_market_cap_usd mc on mc.security_id = sc.security_id
left join market.security_currency cur      on cur.security_id = sc.security_id;

comment on view market.security_facets is
  'The filter spine: every dimension a list can be filtered by, on one row per security. Region, economy tier and income group were seeded in classification_members for 181-221 countries and joined to nothing until this view. cap_band is derived from market_cap_usd (the only comparable figure) and is NULL when no FX rate is known — never guessed.';

grant select on market.security_facets to anon, authenticated, service_role;

notify pgrst, 'reload schema';
