do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_next_earnings';
  if k = 'm' then execute 'drop materialized view if exists market.security_next_earnings cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_next_earnings cascade';
  end if;
end $$;
create view market.security_next_earnings as
SELECT DISTINCT ON (security_id) security_id,
    symbol,
    report_date,
    eps_consensus,
    eps_previous,
    num_estimates,
    reporting_time,
    period_ending,
    report_date >= CURRENT_DATE AS upcoming,
    as_of
   FROM market.earnings_calendar e
  WHERE security_id IS NOT NULL
  ORDER BY security_id, (report_date >= CURRENT_DATE) DESC, (abs(report_date - CURRENT_DATE));
