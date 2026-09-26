do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_insider_summary';
  if k = 'm' then execute 'drop materialized view if exists market.security_insider_summary cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_insider_summary cascade';
  end if;
end $$;
create view market.security_insider_summary as
SELECT security_id,
    count(*) FILTER (WHERE direction = 'Acquisition'::text) AS buys,
    count(*) FILTER (WHERE direction = 'Disposition'::text) AS sells,
    count(DISTINCT owner_name) FILTER (WHERE direction = 'Acquisition'::text) AS buyers,
    count(DISTINCT owner_name) FILTER (WHERE direction = 'Disposition'::text) AS sellers,
    COALESCE(sum(shares) FILTER (WHERE direction = 'Acquisition'::text), 0::numeric) - COALESCE(sum(shares) FILTER (WHERE direction = 'Disposition'::text), 0::numeric) AS net_shares,
    max(transaction_date) AS latest,
    count(*) AS trades
   FROM market.insider_trade t
  WHERE transaction_date >= (CURRENT_DATE - 90)
  GROUP BY security_id;
