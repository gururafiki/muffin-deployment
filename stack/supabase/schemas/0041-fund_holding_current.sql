do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'fund_holding_current';
  if k = 'm' then execute 'drop materialized view if exists market.fund_holding_current cascade';
  elsif k = 'v' then execute 'drop view if exists market.fund_holding_current cascade';
  end if;
end $$;
create view market.fund_holding_current as
SELECT h.fund_id,
    h.security_id,
    h.as_of,
    h.weight,
    h.balance,
    h.market_value,
    h.currency_code,
    h.asset_category_code,
    h.issuer_category_code,
    h.source_code
   FROM market.fund_holding h
     JOIN ( SELECT fund_holding.fund_id,
            max(fund_holding.as_of) AS as_of
           FROM market.fund_holding
          GROUP BY fund_holding.fund_id) latest ON latest.fund_id = h.fund_id AND latest.as_of = h.as_of;
