do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_earnings_surprise';
  if k = 'm' then execute 'drop materialized view if exists market.security_earnings_surprise cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_earnings_surprise cascade';
  end if;
end $$;
create view market.security_earnings_surprise as
SELECT e.security_id,
    e.symbol,
    e.report_date,
    e.period_ending,
    m.as_of AS period_end_date,
    e.eps_consensus AS expected,
    m.value AS actual,
    m.value - e.eps_consensus AS surprise,
        CASE
            WHEN e.eps_consensus <> 0::numeric THEN round((m.value - e.eps_consensus) / abs(e.eps_consensus) * 100::numeric, 2)
            ELSE NULL::numeric
        END AS surprise_pct,
    m.value >= e.eps_consensus AS beat
   FROM market.earnings_calendar e
     JOIN market.security_metric m ON m.security_id = e.security_id AND m.metric_code = 'eps_diluted'::text AND m.period_type = 'quarter'::text AND m.as_of >= (to_date(e.period_ending, 'YYYY-MM'::text) - 7) AND m.as_of < (to_date(e.period_ending, 'YYYY-MM'::text) + '1 mon'::interval + '7 days'::interval)
  WHERE e.security_id IS NOT NULL AND e.eps_consensus IS NOT NULL AND e.report_date <= CURRENT_DATE;
