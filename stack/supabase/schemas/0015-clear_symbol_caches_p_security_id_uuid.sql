CREATE OR REPLACE FUNCTION market.clear_symbol_caches(p_security_id uuid)
 RETURNS void
 LANGUAGE sql
AS $function$
  update market.security set
    industry_missing_at         = null,
    profile_missing_at          = null,
    performance_missing_at      = null,
    fundamentals_missing_at     = null,
    statements_missing_at       = null,
    prices_missing_at           = null,
    quarters_missing_at         = null,
    provider_country_missing_at = null,
    corporate_actions_missing_at = null,
    dividends_missing_at        = null,
    price_history_missing_at    = null,
    daily_history_missing_at    = null,
    share_stats_missing_at      = null,
    estimates_missing_at        = null,
    profile_detail_missing_at   = null
  where security_id = p_security_id;
$function$;
