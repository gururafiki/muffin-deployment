-- THE RETIRED FAMILIES LEAVE THEIR COLUMNS (umbrella docs/deferred/
-- 2026-09-30-the-retired-families-leave-columns-behind.md, the second migration of that note; the
-- tables went in muffin-deployment#479).
--
-- 22 columns that nothing has written since their edge resources retired: the price family
-- (2026-09-12), the universe family (2026-09-26) and the Yahoo company family (2026-10-18). Each was
-- kept as a backup under expand/contract; the Dagster lanes have served every reader since.
--
-- MEASURED ON PRODUCTION 2026-11-22, with the note's proving query (`pg_depend` for views, the
-- function bodies of `market`, `api` and `ingest`), and by grepping muffin-ui, muffin-ingest, the
-- edge functions, Grafana and the workflows:
--   - `performance_missing_at` was read by one view, `data_defect`, for its
--     `contradicted_negative_cache` arm: a GAUGE in both market-verify and the Grafana rule since
--     2026-09-05, counting marks that nothing has set since 2026-09-12. The arm goes first.
--   - the ten Yahoo columns were read only by `clear_symbol_caches`, which the trigger
--     `provider_symbol_clears_caches` calls when a security's provider symbol changes. It now
--     clears the one symbol-keyed column left, and their classification rows go.
--   - `tracked_fund.last_report_date`: the proving query matched `sample_universe`, which reads
--     the column of the same name on `tracked_fund_latest`, derived from `fund_holding`. Nothing
--     reads the table's column.
--   - nothing reads the other ten.
--
-- KEPT, for Phase 5's contract on 2026-12-07 (the note's own list):
--   - `currency.history_missing_at`: muffin-ingest's FX lane still reads it (`askable_currencies`).
--     The one mark is from 2026-08-21, past its 30 days, so the read passes every currency, but
--     dropping the column would break the query. The read goes first, in muffin-ingest.
--   - `corporate_actions_missing_at`: its Tiingo writer retired on 2026-10-25, 28 days ago.
--     With it gone, `clear_symbol_caches` clears nothing, so it, its trigger and
--     `symbol_cache_classification` can go too, beside `statement_currency_missing_at` and
--     `xbrl_missing_at`.
--
-- Dropping a column is a catalogue change: no table rewrite, a brief ACCESS EXCLUSIVE lock on
-- `market.security`.

-- 1. `data_defect` without the `contradicted_negative_cache` gauge. Same columns, so the grants stay.
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

-- 2. `clear_symbol_caches` clears the symbol-keyed column left. `create or replace` keeps its ACL.
create or replace function market.clear_symbol_caches(p_security_id uuid)
 returns void
 language sql
as $function$
  update market.security set
    corporate_actions_missing_at = null
  where security_id = p_security_id;
$function$;

-- 3. The classification names only columns that exist (`negative-caches-are-classified.sql`).
create or replace view market.symbol_cache_classification as
select column_name, symbol_keyed, reason
  from (values
    ('corporate_actions_missing_at'::text, true, 'Tiingo EOD fetched by the US ticker'::text),
    ('statement_currency_missing_at'::text, false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'::text),
    ('xbrl_missing_at'::text, false, 'company facts are asked for by CIK; a new provider symbol says nothing about the filer'::text),
    ('wikidata_missing_at'::text, false, 'Wikidata is asked for by ISIN; a corrected provider symbol says nothing about a Wikidata entity, and clearing it would re-ask a public endpoint for an answer already held'::text)
  ) t(column_name, symbol_keyed, reason);

-- 4. The columns.
alter table market.security
  drop column if exists prices_missing_at,
  drop column if exists performance_missing_at,
  drop column if exists price_history_missing_at,
  drop column if exists daily_history_missing_at,
  drop column if exists price_history_from,
  drop column if exists daily_history_from,
  drop column if exists figi_missing_at,
  drop column if exists local_symbol_missing_at,
  drop column if exists yahoo_symbol_missing_at,
  drop column if exists symbol_repair_at,
  drop column if exists industry_missing_at,
  drop column if exists profile_missing_at,
  drop column if exists provider_country_missing_at,
  drop column if exists profile_detail_missing_at,
  drop column if exists fundamentals_missing_at,
  drop column if exists statements_missing_at,
  drop column if exists quarters_missing_at,
  drop column if exists dividends_missing_at,
  drop column if exists share_stats_missing_at,
  drop column if exists estimates_missing_at,
  drop column if exists management_fetched_at;

alter table market.tracked_fund drop column if exists last_report_date;
