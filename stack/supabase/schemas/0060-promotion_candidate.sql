do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'promotion_candidate';
  if k = 'm' then execute 'drop materialized view if exists market.promotion_candidate cascade';
  elsif k = 'v' then execute 'drop view if exists market.promotion_candidate cascade';
  end if;
end $$;
create view market.promotion_candidate as
WITH live AS (
         SELECT v.figi,
            v.composite_figi,
            v.share_class_figi,
            v.exch_code,
            v.ticker,
            v.name,
            v.provider_symbol,
            v.security_type,
            e.country_iso2,
            e.promotion_enabled,
            e.promotion_tier,
            e.preference,
            count(*) OVER w AS listings,
            min(e.country_iso2) OVER w AS country_min,
            max(e.country_iso2) OVER w AS country_max
           FROM market.venue_listing v
             JOIN market.exchange e ON e.exch_code = v.exch_code
          WHERE v.absent_since IS NULL AND v.share_class_figi IS NOT NULL
          WINDOW w AS (PARTITION BY v.share_class_figi)
        ), chosen AS (
         SELECT DISTINCT ON (l.share_class_figi) l.figi,
            l.composite_figi,
            l.share_class_figi,
            l.exch_code,
            l.ticker,
            l.name,
            l.provider_symbol,
            l.security_type,
            l.country_iso2,
            l.promotion_enabled,
            l.promotion_tier,
            l.preference,
            l.listings,
            l.country_min,
            l.country_max
           FROM live l
          WHERE l.promotion_enabled AND l.country_min = l.country_max AND l.name IS NOT NULL AND (l.security_type = ANY (ARRAY['Common Stock'::text, 'REIT'::text])) AND l.ticker !~ '^[0-9]{5,}[A-Z]$'::text
          ORDER BY l.share_class_figi, l.preference, l.exch_code, l.figi
        )
 SELECT share_class_figi,
    figi,
    composite_figi,
    exch_code,
    ticker,
    name,
    country_iso2,
    provider_symbol,
    security_type,
    promotion_tier,
    preference,
    listings
   FROM chosen ch
  WHERE NOT (EXISTS ( SELECT 1
           FROM market.security_identifier si
          WHERE si.kind_code = 'share_class_figi'::text AND si.value = ch.share_class_figi)) AND NOT (EXISTS ( SELECT 1
           FROM market.security_identifier si
          WHERE si.kind_code = 'figi'::text AND si.value = COALESCE(ch.composite_figi, ch.figi))) AND NOT (EXISTS ( SELECT 1
           FROM market.security_provider_symbol ps
          WHERE upper(ps.symbol) = upper(ch.provider_symbol))) AND NOT (EXISTS ( SELECT 1
           FROM market.security_identifier ti
          WHERE ti.kind_code = 'ticker'::text AND upper(ti.value) = upper(ch.provider_symbol))) AND NOT (EXISTS ( SELECT 1
           FROM market.promotion_probe pp
          WHERE pp.figi = ch.figi AND pp.outcome <> 'priced'::text AND pp.observed_at > (now() - '90 days'::interval)));
