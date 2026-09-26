do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_funds';
  if k = 'm' then execute 'drop materialized view if exists market.security_funds cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_funds cascade';
  end if;
end $$;
create view market.security_funds as
SELECT h.security_id,
    fi.value AS fund_symbol,
    COALESCE(tf.name, fs.name) AS fund_name,
    tf.kind AS fund_kind,
    tf.represents_code,
    h.weight,
    h.as_of
   FROM market.fund_holding_current h
     JOIN market.security_identifier fi ON fi.security_id = h.fund_id AND fi.kind_code = 'ticker'::text
     JOIN market.security fs ON fs.security_id = h.fund_id
     LEFT JOIN market.tracked_fund tf ON tf.symbol = fi.value
  WHERE h.security_id <> h.fund_id;
