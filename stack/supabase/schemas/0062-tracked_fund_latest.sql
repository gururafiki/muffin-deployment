do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'tracked_fund_latest';
  if k = 'm' then execute 'drop materialized view if exists market.tracked_fund_latest cascade';
  elsif k = 'v' then execute 'drop view if exists market.tracked_fund_latest cascade';
  end if;
end $$;
create view market.tracked_fund_latest as
SELECT tf.symbol,
    i.security_id AS fund_id,
    max(h.as_of) AS last_report_date
   FROM market.tracked_fund tf
     LEFT JOIN market.security_identifier i ON i.kind_code = 'ticker'::text AND i.value = tf.symbol
     LEFT JOIN market.fund_holding h ON h.fund_id = i.security_id
  GROUP BY tf.symbol, i.security_id;
