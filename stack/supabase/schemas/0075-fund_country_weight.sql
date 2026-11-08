do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'fund_country_weight';
  if k = 'm' then execute 'drop materialized view if exists market.fund_country_weight cascade';
  elsif k = 'v' then execute 'drop view if exists market.fund_country_weight cascade';
  end if;
end $$;
create view market.fund_country_weight as
SELECT fi.value AS fund_symbol,
    COALESCE(s.provider_country_iso2, s.country_iso2, 'XX'::text) AS country_iso2,
    sum(h.weight) AS weight,
    round(100::numeric * sum(h.weight) / NULLIF(sum(sum(h.weight)) OVER (PARTITION BY fi.value), 0::numeric), 4) AS weight_pct,
    max(h.as_of) AS as_of
   FROM market.fund_holding_current h
     JOIN market.security_identifier fi ON fi.security_id = h.fund_id AND fi.kind_code = 'ticker'::text
     JOIN market.security s ON s.security_id = h.security_id
  WHERE h.security_id <> h.fund_id
  GROUP BY fi.value, (COALESCE(s.provider_country_iso2, s.country_iso2, 'XX'::text));
