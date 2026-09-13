do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'ticker_disagreement';
  if k = 'm' then execute 'drop materialized view if exists market.ticker_disagreement cascade';
  elsif k = 'v' then execute 'drop view if exists market.ticker_disagreement cascade';
  end if;
end $$;
create view market.ticker_disagreement as
SELECT s.security_id,
    s.name,
    s.country_iso2,
    f.us_ticker AS sec_ticker,
    f.us_exchange AS sec_exchange,
    i.value AS openfigi_ticker,
    COALESCE(max(h.weight), 0::numeric) AS best_weight
   FROM market.filer_profile f
     JOIN market.security s ON s.security_id = f.security_id
     LEFT JOIN market.security_identifier i ON i.security_id = f.security_id AND i.kind_code = 'ticker'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = f.security_id
  WHERE f.us_ticker IS NOT NULL AND i.value IS DISTINCT FROM f.us_ticker
  GROUP BY s.security_id, s.name, s.country_iso2, f.us_ticker, f.us_exchange, i.value
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
