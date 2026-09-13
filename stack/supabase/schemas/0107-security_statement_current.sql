do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_statement_current';
  if k = 'm' then execute 'drop materialized view if exists market.security_statement_current cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_statement_current cascade';
  end if;
end $$;
create view market.security_statement_current as
SELECT sym.symbol,
    st.security_id,
    st.statement,
    st.period_ending,
    st.period_type,
    st.currency,
    st.data,
    st.source_code,
    st.as_of,
    st.derived_at,
    s.currency_code,
    COALESCE(s.provider_country_iso2, s.country_iso2) AS country_iso2,
        CASE
            WHEN st.currency IS NOT NULL THEN st.currency
            WHEN s.currency_code IS NULL THEN NULL::text
            WHEN s.currency_code <> 'USD'::text THEN s.currency_code
            WHEN COALESCE(s.provider_country_iso2, s.country_iso2) = 'US'::text THEN s.currency_code
            ELSE NULL::text
        END AS reporting_currency
   FROM market.security_statement st
     JOIN market.security_symbol sym ON sym.security_id = st.security_id
     JOIN market.security s ON s.security_id = st.security_id;
