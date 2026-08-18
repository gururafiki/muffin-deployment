-- 3,596 SECURITIES — 29% OF THE EQUITY UNIVERSE — WERE SILENTLY MISSING FROM EVERY PER-COUNTRY
-- SECTOR NUMBER, AND NOTHING REPORTED IT.
--
-- `country_sector_performance` resolves a constituent's symbol as `coalesce(ticker, yfinance)` —
-- US ticker FIRST. Migration 39 re-keyed `performance.scope_id` to `security_symbol.symbol`, whose
-- precedence is the OPPOSITE: primary listing, then local line, then the US/OTC ticker. So every
-- security whose primary listing is not its US ticker joined to nothing.
--
-- Measured 2026-08-18 before this fix:
--
--   symbol precedence differs                    3,827 equities
--   HAVE performance under the correct key but
--   NOT under the stale one  (silently dropped)  3,596
--   country_sector_performance rows                1,359 across 29 countries
--
-- That is the whole reason the app shows sector breakdowns for only ~29 of 45 drillable countries.
-- It reads as "we have no data for this market" and is actually "we joined on the wrong column".
--
-- The signature to recognise: a join key produced by DIFFERENT precedence logic than the key it is
-- being matched against. Migration 39 changed one side and this view kept the other, and because a
-- failed join yields FEWER ROWS rather than an error, nothing anywhere raised.
--
-- THREE OTHER THINGS ARE WRONG IN THE SAME VIEW, all the same class:
--
--   1. `where s.country_iso2 is not null` uses the FILED country. Migration 56 moved everything
--      else to the effective country (`coalesce(provider, filed)`) precisely because Alibaba files
--      in the Cayman Islands and operates in China. 212 equities differ.
--   2. `tf.represents_code = s.country_iso2` matches the country FUND on the filed country too, so
--      an offshore-incorporated Chinese company can never match the China ETF.
--   3. It reads only `change_pct`. `total_return_pct` has existed since migration 72 and every
--      other aggregate can serve it.

-- ── 1. fund_country_weight: the same filed-vs-effective bug ───────────────────────────────────
--
-- Column shape is unchanged, so `create or replace` is safe here; only the expression moves to the
-- effective country. Alibaba counted as `KY` in a fund's country donut while appearing as `CN` on
-- every other screen — two screens disagreeing about the same company.
create or replace view market.fund_country_weight as
select
  fi.value as fund_symbol,
  coalesce(s.provider_country_iso2, s.country_iso2, 'XX') as country_iso2,
  sum(h.weight) as weight,
  round(100 * sum(h.weight) / nullif(sum(sum(h.weight)) over (partition by fi.value), 0), 4) as weight_pct,
  max(h.as_of) as as_of
from market.fund_holding_current h
join market.security_identifier fi on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
join market.security s on s.security_id = h.security_id
where h.security_id <> h.fund_id
group by fi.value, coalesce(s.provider_country_iso2, s.country_iso2, 'XX');

-- ── 2. country_sector_performance: join on the key performance is actually stored under ───────
--
-- Dropped rather than replaced: this adds `total_return_pct`, and while `create or replace` can
-- APPEND a column it cannot reorder — and putting the new column in its natural place beside
-- `change_pct` is worth the drop. Nothing depends on this view (checked via pg_depend).
drop view if exists market.country_sector_performance;

create view market.country_sector_performance as
with constituent as (
  select distinct on (s.security_id)
    s.security_id,
    -- EFFECTIVE country, matching every other view since migration 56.
    coalesce(s.provider_country_iso2, s.country_iso2) as country_iso2,
    tn.code as sector_id,
    -- THE KEY `performance` IS ACTUALLY STORED UNDER. `security_symbol` is the single definition
    -- of a security's display symbol (migration 39), and `security-performance` writes
    -- `scope_id = security_symbol.symbol`. Any other spelling here is a join that silently matches
    -- nothing.
    sym.symbol,
    h.weight,
    tf.symbol as fund_symbol
  from market.security s
  join market.security_taxonomy st on st.security_id = s.security_id
  join market.taxonomy_node tn
    on tn.node_id = st.node_id and tn.taxonomy_id = 'muffin' and tn.level = 1
  join market.data_source ds on ds.code = st.source_code
  join market.security_symbol sym on sym.security_id = s.security_id
  join market.fund_holding_current h on h.security_id = s.security_id
  join market.security_identifier fi
    on fi.security_id = h.fund_id and fi.kind_code = 'ticker'
  join market.tracked_fund tf
    on tf.symbol = fi.value and tf.kind = 'country'
   and tf.represents_code = coalesce(s.provider_country_iso2, s.country_iso2)
  where coalesce(s.provider_country_iso2, s.country_iso2) is not null
    and s.security_type_code = 'equity'
    and h.weight > 0
    and sym.symbol is not null
  order by s.security_id, ds.priority desc, st.as_of desc
)
select
  c.country_iso2,
  c.sector_id,
  p.period,
  round(sum(c.weight * p.change_pct) / nullif(sum(c.weight), 0), 4) as change_pct,
  -- TOTAL RETURN, over only the rows that HAVE one. Migration 72 is emphatic that NULL means
  -- "not computed" and must never be coalesced to `change_pct` — that would erase the difference
  -- between "paid no income" and "we do not know". So the weighted mean runs over the non-null
  -- subset and `total_return_constituents` says how many that was, rather than quietly averaging
  -- a mixture.
  round(
    sum(c.weight * p.total_return_pct) filter (where p.total_return_pct is not null)
    / nullif(sum(c.weight) filter (where p.total_return_pct is not null), 0)
  , 4) as total_return_pct,
  count(*) as constituents,
  count(*) filter (where p.total_return_pct is not null) as total_return_constituents,
  round(sum(c.weight), 4) as weight_covered,
  min(c.fund_symbol) as fund_symbol,
  max(p.as_of) as as_of
from constituent c
join market.performance p
  on p.scope = 'instrument' and p.scope_id = c.symbol
group by c.country_iso2, c.sector_id, p.period;

grant select on market.country_sector_performance to anon, authenticated, service_role;

notify pgrst, 'reload schema';
