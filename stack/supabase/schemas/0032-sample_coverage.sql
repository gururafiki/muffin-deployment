CREATE OR REPLACE FUNCTION market.sample_coverage()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  ts timestamptz := now();
  n  integer;
begin
  insert into market.coverage_sample (
    sampled_at, dimension, bucket, security_type_code, securities, segment_capable, complete,
    present_facets, applicable_facets,
    with_symbol, with_sector, with_industry, with_price, with_performance,
    with_profile, with_fundamentals, with_statements, with_metrics,
    priced_3d, priced_7d, priced_30d,
    with_price_history, with_daily_history, with_news, with_leadership, with_insider,
    with_filings, with_dividends, with_share_stats, with_estimates, with_quarters,
    with_sic, with_segments, with_segment_geography, with_weighted_industry)
  select ts, dimension, bucket, security_type_code, securities, segment_capable, complete,
         present_facets, applicable_facets,
         with_symbol, with_sector, with_industry, with_price, with_performance,
         with_profile, with_fundamentals, with_statements, with_metrics,
         priced_3d, priced_7d, priced_30d,
         with_price_history, with_daily_history, with_news, with_leadership, with_insider,
         with_filings, with_dividends, with_share_stats, with_estimates, with_quarters,
         with_sic, with_segments, with_segment_geography, with_weighted_industry
    from market.coverage_current
  on conflict (sampled_at, dimension, bucket, security_type_code) do nothing;

  get diagnostics n = row_count;
  return n;
end $function$;
