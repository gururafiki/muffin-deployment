-- The Yahoo company family's backlog views leave with their handlers. Phase 4 step 10 of the
-- umbrella's docs/specs/2026-10-10-yahoo-company-data.md.
--
-- The family retired on 2026-10-18 (step 9, migration 20261018200000): ten resources answer 410
-- and the Dagster company lane owns their data. This change deletes the handlers from
-- `market-refresh`, so the eight views that queued work for them queue work nothing can do.
-- `pending_metrics` and `pending_ttm` stay: `derived_security_metrics` drains them in Dagster.
--
-- CHECKED BEFORE DROPPING, on production 2026-10-24:
--   - the only dependent of any of the eight is `market.data_defect`, through its
--     `queued_but_already_done` arm over `pending_industry` (pg_depend through pg_rewrite);
--   - no function in `market`, `api` or `ingest` names one;
--   - muffin-ui, muffin-ingest and muffin-agent read none of them (each mention is a comment);
--   - `backlogs_to_sample()` lists the `pending_%` views from the catalogue, so the samples, the
--     dashboards and the FLAT alert follow on their own.
--
-- THE ARM GOES BEFORE THE VIEW. It asked "is anything already classified still queued for an
-- industry", a guard written for the 2026-08-11 stall, and with `pending_industry` gone there is
-- no queue to ask about. Removing a union arm keeps the view's columns, so `create or replace`
-- applies and keeps the grants (a `drop view` would lose them). market-verify's check 7b and
-- tests/backlogs-are-satisfiable.sql, its two other guards, leave in the same change.
--
-- THE CURSOR AND NEGATIVE-CACHE COLUMNS STAY FOR NOW: `industry_missing_at`, `profile_missing_at`,
-- `fundamentals_missing_at`, `quarters_missing_at`, `dividends_missing_at`,
-- `share_stats_missing_at`, `profile_detail_missing_at`, `management_fetched_at` and the rest. They
-- are dropped with the other retired columns at the contract step
-- (docs/deferred/2026-09-30-the-retired-families-leave-columns-behind.md, umbrella), together
-- with their entries in `clear_symbol_caches` and `symbol_cache_classification`, which
-- tests/negative-caches-are-classified.sql holds equal.

create or replace view market.data_defect as
SELECT 'placeholder_cusip'::text AS defect,
    count(*) AS n,
    'security_identifier rows with the all-zero CUSIP placeholder'::text AS detail
   FROM market.security_identifier
  WHERE security_identifier.kind_code = 'cusip'::text AND security_identifier.value = '000000000'::text
UNION ALL
 SELECT 'placeholder_isin'::text AS defect,
    count(*) AS n,
    'security_identifier rows with the all-zero ISIN placeholder'::text AS detail
   FROM market.security_identifier
  WHERE security_identifier.kind_code = 'isin'::text AND security_identifier.value = '000000000000'::text
UNION ALL
 SELECT 'duplicate_constituents'::text AS defect,
    COALESCE(sum(q.rows_ - q.distinct_), 0::numeric) AS n,
    'sector_constituents rows beyond one per security, across ALL sectors'::text AS detail
   FROM ( SELECT sector_constituents.sector_id,
            count(*) AS rows_,
            count(DISTINCT sector_constituents.security_id) AS distinct_
           FROM market.sector_constituents
          GROUP BY sector_constituents.sector_id) q
UNION ALL
 SELECT 'returns_at_minus_100'::text AS defect,
    count(*) AS n,
    'performance rows at exactly -100% — a zero close became a total loss'::text AS detail
   FROM market.performance
  WHERE performance.scope = 'instrument'::text AND performance.change_pct = '-100'::integer::numeric
UNION ALL
 SELECT 'frozen_series'::text AS defect,
    count(*) AS n,
    'symbols whose FRESH refresh is 0.00% on every period it produced (3+ periods)'::text AS detail
   FROM ( SELECT performance.scope_id
           FROM market.performance
          WHERE performance.scope = 'instrument'::text AND performance.as_of > (now() - '2 days'::interval)
          GROUP BY performance.scope_id
         HAVING count(*) FILTER (WHERE performance.change_pct = 0::numeric) >= 3 AND count(*) FILTER (WHERE performance.change_pct IS NOT NULL AND performance.change_pct <> 0::numeric) = 0) q
UNION ALL
 SELECT 'contradicted_negative_cache'::text AS defect,
    count(*) AS n,
    'securities marked as having no returns while holding recent bars that MOVE'::text AS detail
   FROM market.security s
  WHERE s.performance_missing_at IS NOT NULL AND (( SELECT count(DISTINCT p.close) AS count
           FROM market.price_bar p
          WHERE p.security_id = s.security_id AND p.trade_date > (CURRENT_DATE - 30))) > 1 AND (EXISTS ( SELECT 1
           FROM market.price_bar p
          WHERE p.security_id = s.security_id AND p.trade_date > (CURRENT_DATE - 7)))
UNION ALL
 SELECT 'country_with_no_symbols'::text AS defect,
    count(*) AS n,
    'countries with 20+ equities and not one provider symbol'::text AS detail
   FROM ( SELECT s.country_iso2
           FROM market.security s
          WHERE s.security_type_code = 'equity'::text AND s.country_iso2 IS NOT NULL
          GROUP BY s.country_iso2
         HAVING count(*) >= 20 AND NOT (EXISTS ( SELECT 1
                   FROM market.security s2
                  WHERE s2.country_iso2 = s.country_iso2 AND ((EXISTS ( SELECT 1
                           FROM market.security_provider_symbol sp
                          WHERE sp.security_id = s2.security_id)) OR (EXISTS ( SELECT 1
                           FROM market.security_identifier i
                          WHERE i.security_id = s2.security_id AND i.kind_code = 'ticker'::text)))))) q
UNION ALL
 SELECT 'extreme_1y_returns'::text AS defect,
    count(*) AS n,
    'GAUGE not an invariant: 1y returns >= +1000%, expected non-zero and stable'::text AS detail
   FROM market.performance
  WHERE performance.scope = 'instrument'::text AND performance.period = '1y'::text AND performance.change_pct >= 1000::numeric;

do $$
declare
  v text;
  k char;
begin
  foreach v in array array[
    'pending_profile', 'pending_profile_detail', 'pending_industry', 'pending_fundamentals',
    'pending_share_stats', 'pending_management', 'pending_quarters', 'pending_dividends'
  ] loop
    -- relkind-aware: `drop view if exists` raises on a materialized view of the same name.
    select c.relkind into k
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'market' and c.relname = v;
    if k = 'v' then
      execute format('drop view market.%I', v);
    elsif k = 'm' then
      execute format('drop materialized view market.%I', v);
    end if;
  end loop;
end $$;

delete from market.backlog_negative_cache
 where backlog in ('pending_profile', 'pending_profile_detail', 'pending_industry',
                   'pending_fundamentals', 'pending_share_stats', 'pending_management',
                   'pending_quarters', 'pending_dividends');
