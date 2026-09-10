do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_segment_geography';
  if k = 'm' then execute 'drop materialized view if exists market.security_segment_geography cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_segment_geography cascade';
  end if;
end $$;
create view market.security_segment_geography as
SELECT security_id,
    member_code,
    country_iso2,
    member_label,
    axis,
    revenue,
    operating_income,
    revenue_share_pct,
    currency_code,
    period_ending,
    accession_number
   FROM market.security_segment_spine c
  WHERE kind = 'geography'::text AND member_label IS NOT NULL;
