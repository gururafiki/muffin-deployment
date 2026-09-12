do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'pending_profile';
  if k = 'm' then execute 'drop materialized view if exists market.pending_profile cascade';
  elsif k = 'v' then execute 'drop view if exists market.pending_profile cascade';
  end if;
end $$;
create view market.pending_profile as
SELECT s.security_id,
    COALESCE(ps.symbol, t.value) AS symbol,
    s.name,
    COALESCE(max(h.weight), 0::numeric) AS best_weight,
        CASE
            WHEN st.security_id IS NULL THEN 'sector'::text
            ELSE 'country'::text
        END AS want
   FROM market.security s
     LEFT JOIN market.security_provider_symbol ps ON ps.security_id = s.security_id AND ps.provider_code = 'yfinance'::text
     LEFT JOIN market.security_identifier t ON t.security_id = s.security_id AND t.kind_code = 'ticker'::text
     LEFT JOIN market.security_taxonomy st ON st.security_id = s.security_id AND st.source_code = 'yfinance'::text
     LEFT JOIN market.fund_holding_current h ON h.security_id = s.security_id
  WHERE s.security_type_code = 'equity'::text AND COALESCE(ps.symbol, t.value) IS NOT NULL AND (st.security_id IS NULL AND (s.profile_missing_at IS NULL OR s.profile_missing_at < (now() - '30 days'::interval)) OR s.provider_country_iso2 IS NULL AND (s.country_iso2 IS NULL OR NOT (EXISTS ( SELECT 1
           FROM market.countries c
          WHERE c.iso2 = s.country_iso2 AND c.drillable))) AND (s.provider_country_missing_at IS NULL OR s.provider_country_missing_at < (now() - '30 days'::interval)))
  GROUP BY s.security_id, (COALESCE(ps.symbol, t.value)), s.name, st.security_id
  ORDER BY (COALESCE(max(h.weight), 0::numeric)) DESC;
