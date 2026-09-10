CREATE OR REPLACE FUNCTION market.sample_quality()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'market', 'pg_catalog', 'pg_temp'
AS $function$
declare
  ts    timestamptz := now();
  taken integer := 0;
begin
  perform set_config('statement_timeout', '30s', true);

  -- The invariants, as trends rather than a nightly bit.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, 'defect.' || defect, n from market.data_defect
  on conflict do nothing;
  get diagnostics taken = row_count;

  insert into market.universe_sample (sampled_at, metric, value)
  select ts, 'out_of_range.' || metric_code, n from market.metric_out_of_range
  on conflict do nothing;

  -- THE UNIT-FLIP TRIPWIRE. p50 and p99 per metric — 149 ms for all 16 codes, measured. The
  -- fraction/percent confusion has hit this schema THREE times: OpenBB returning performance as a
  -- fraction, the shared `pct()` that rendered NVIDIA at a 46% dividend yield, and
  -- `surprise_percent`. Every one was invisible per row and obvious in the aggregate. A p50 that
  -- moves 100x between two samples is a unit change, and this catches the whole CLASS rather than
  -- one metric at a time.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, 'dist.' || metric_code || '.' || stat, v from (
    select metric_code, 'p50' as stat, percentile_cont(0.5) within group (order by value) as v
      from market.security_metric where period_type = 'ttm' group by metric_code
    union all
    select metric_code, 'p99', percentile_cont(0.99) within group (order by value)
      from market.security_metric where period_type = 'ttm' group by metric_code
  ) q where v is not null
  on conflict do nothing;

  -- PROVENANCE. Measured sec-xbrl 2,114,386 / derived 693,306 / yfinance 614,212 / sec 3,896.
  -- A sudden shift means a provider changed behaviour or a resource stopped writing — neither of
  -- which any count of rows can show, because the total barely moves while the mix does.
  insert into market.universe_sample (sampled_at, metric, value)
  select ts, 'provenance.' || source_code, count(*) from market.security_metric
   group by source_code
  on conflict do nothing;

  return taken;
end $function$;
