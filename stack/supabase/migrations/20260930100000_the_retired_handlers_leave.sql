-- The retired families' backlog views leave with their handlers. Stage 1c of the umbrella's
-- docs/specs/2026-09-26-finishing-the-universe-family.md.
--
-- The price family retired on 2026-09-12 (D2) and the universe family on 2026-09-26 (1b). Both
-- kept their edge handlers behind a 410 until the Dagster lanes had run clean for three days; this
-- change deletes the handlers from `market-refresh`, so the ten views that queued work for them
-- queue work nothing can do.
--
-- CHECKED BEFORE DROPPING, on production 2026-09-30: no view depends on any of the ten (pg_depend
-- through pg_rewrite), no function in `market` names one, and muffin-ui reads none of them.
-- `backlogs_to_sample()` lists the `pending_%` views from the catalogue, so the samples, the
-- dashboards and the FLAT alert follow on their own.
--
-- THE NEGATIVE-CACHE COLUMNS STAY FOR NOW. `prices_missing_at`, `performance_missing_at`,
-- `price_history_missing_at` and `daily_history_missing_at` recorded answers for the retired price
-- family; nothing reads them after this. They are dropped with the rest of the retired columns at
-- the contract step (docs/deferred/2026-09-30-the-retired-families-leave-columns-behind.md,
-- umbrella). Until then `clear_symbol_caches` stops clearing them — a corrected symbol has nothing
-- to re-queue there — and the classification says so, which is what
-- tests/negative-caches-are-classified.sql holds the function to.

do $$
declare
  v text;
  k char;
begin
  foreach v in array array[
    'pending_ticker', 'pending_local_symbol', 'pending_yahoo_symbol', 'pending_symbol_repair',
    'pending_promotion', 'pending_prices', 'pending_price_history', 'pending_daily_history',
    'pending_performance', 'pending_fx_history'
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
 where backlog in ('pending_ticker', 'pending_local_symbol', 'pending_yahoo_symbol',
                   'pending_symbol_repair', 'pending_promotion', 'pending_prices',
                   'pending_price_history', 'pending_daily_history', 'pending_performance',
                   'pending_fx_history');

create or replace function market.clear_symbol_caches(p_security_id uuid)
returns void
language sql
as $function$
  update market.security set
    industry_missing_at         = null,
    profile_missing_at          = null,
    fundamentals_missing_at     = null,
    statements_missing_at       = null,
    quarters_missing_at         = null,
    provider_country_missing_at = null,
    corporate_actions_missing_at = null,
    dividends_missing_at        = null,
    share_stats_missing_at      = null,
    estimates_missing_at        = null,
    profile_detail_missing_at   = null
  where security_id = p_security_id;
$function$;

create or replace view market.symbol_cache_classification as
select column_name, symbol_keyed, reason
  from (values
    ('industry_missing_at', true, 'yfinance profile fetched by symbol'),
    ('profile_missing_at', true, 'yfinance profile fetched by symbol'),
    ('performance_missing_at', false, 'retired with the price family (D2); nothing reads it, and it is dropped at the contract step'),
    ('fundamentals_missing_at', true, 'metrics fetched by symbol'),
    ('statements_missing_at', true, 'statements fetched by symbol'),
    ('prices_missing_at', false, 'retired with the price family (D2); nothing reads it, and it is dropped at the contract step'),
    ('quarters_missing_at', true, 'quarterly statements fetched by the PRICED symbol'),
    ('provider_country_missing_at', true, 'yfinance profile fetched by symbol'),
    ('corporate_actions_missing_at', true, 'Tiingo EOD fetched by the US ticker'),
    ('dividends_missing_at', true, 'yfinance dividends fetched by the PRICED symbol'),
    ('price_history_missing_at', false, 'retired with the price family (D2); nothing reads it, and it is dropped at the contract step'),
    ('daily_history_missing_at', false, 'retired with the price family (D2); nothing reads it, and it is dropped at the contract step'),
    ('share_stats_missing_at', true, 'share statistics fetched by the PRICED symbol'),
    ('estimates_missing_at', true, 'analyst consensus fetched by the PRICED symbol'),
    ('profile_detail_missing_at', true, 'yfinance profile fetched by symbol'),
    ('figi_missing_at', false, 'OpenFIGI asked for the ISIN, not the symbol'),
    ('local_symbol_missing_at', false, 'keyed on ISIN/FIGI, not the symbol'),
    ('yahoo_symbol_missing_at', false, 'the resolver''s own flag — clearing it here would loop'),
    ('statement_currency_missing_at', false, 'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'),
    ('xbrl_missing_at', false, 'company facts are asked for by CIK; a new provider symbol says nothing about the filer'),
    ('wikidata_missing_at', false, 'Wikidata is asked for by ISIN; a corrected provider symbol says nothing about a Wikidata entity, and clearing it would re-ask a public endpoint for an answer already held')
  ) t(column_name, symbol_keyed, reason);
