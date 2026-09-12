do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_segment_spine';
  if k = 'm' then execute 'drop materialized view if exists market.security_segment_spine cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_segment_spine cascade';
  end if;
end $$;
create materialized view market.security_segment_spine as
SELECT security_id,
    axis,
    kind,
    member_code,
    concept_code,
    concept_name,
    revenue,
    operating_income,
    capital_expenditure,
    depreciation,
    cost_of_revenue,
    total_assets,
    operating_margin_pct,
    gross_margin_pct,
    capex_to_depreciation,
    return_on_segment_assets_pct,
    revenue_share_pct,
    currency_code,
    period_ending,
    accession_number,
    reconciled_to,
    country_iso2,
    member_label,
    long_lived_assets,
    goodwill
   FROM market.security_segment_current;
