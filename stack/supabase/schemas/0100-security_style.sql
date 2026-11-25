do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_style';
  if k = 'm' then execute 'drop materialized view if exists market.security_style cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_style cascade';
  end if;
end $$;
create view market.security_style as
WITH scoreable AS (
         SELECT f.security_id,
            1.0 / f.price_to_book AS book_to_price,
            cm.group_id AS tier,
                CASE
                    WHEN mc.market_cap_usd >= '10000000000'::numeric THEN 'large'::text
                    WHEN mc.market_cap_usd >= '2000000000'::numeric THEN 'mid'::text
                    WHEN mc.market_cap_usd > 0::numeric THEN 'small'::text
                    ELSE NULL::text
                END AS cap_band
           FROM market.security_fundamentals f
             JOIN market.security_current sc_1 ON sc_1.security_id = f.security_id
             JOIN market.security s ON s.security_id = f.security_id
             JOIN market.classification_members cm ON cm.iso2 = sc_1.country_iso2 AND cm.scheme_id = 'msci'::text AND cm.lens = 'tier'::text
             JOIN market.security_market_cap_usd mc ON mc.security_id = f.security_id
          WHERE s.security_type_code = 'equity'::text AND f.price_to_book IS NOT NULL AND f.price_to_book > 0::numeric AND mc.market_cap_usd > 0::numeric
        ), cohorted AS (
         SELECT scoreable.security_id,
            scoreable.book_to_price,
            (scoreable.tier || '/'::text) || scoreable.cap_band AS cohort,
            count(*) OVER (PARTITION BY scoreable.tier, scoreable.cap_band) AS cohort_size,
            percent_rank() OVER (PARTITION BY scoreable.tier, scoreable.cap_band ORDER BY scoreable.book_to_price) AS value_score
           FROM scoreable
        ), scored AS (
         SELECT cohorted.security_id,
            cohorted.book_to_price,
            cohorted.cohort,
            cohorted.cohort_size,
            cohorted.value_score
           FROM cohorted
          WHERE cohorted.cohort_size >= 30
        ), index_label AS (
         SELECT h.security_id,
                CASE
                    WHEN count(*) FILTER (WHERE fi.value = 'IWF'::text) > 0 AND count(*) FILTER (WHERE fi.value = 'IWD'::text) > 0 THEN 'blend'::text
                    WHEN count(*) FILTER (WHERE fi.value = 'IWF'::text) > 0 THEN 'growth'::text
                    WHEN count(*) FILTER (WHERE fi.value = 'IWD'::text) > 0 THEN 'value'::text
                    ELSE NULL::text
                END AS style
           FROM market.fund_holding_current h
             JOIN market.security_identifier fi ON fi.security_id = h.fund_id AND fi.kind_code = 'ticker'::text
          WHERE fi.value = ANY (ARRAY['IWF'::text, 'IWD'::text])
          GROUP BY h.security_id
        )
 SELECT sc.security_id,
    round(sc.value_score::numeric, 4) AS value_score,
    round(sc.book_to_price, 4) AS book_to_price,
    sc.cohort,
    sc.cohort_size,
    COALESCE(il.style,
        CASE
            WHEN sc.value_score >= 0.29::double precision THEN 'value'::text
            WHEN sc.value_score <= 0.10::double precision THEN 'growth'::text
            ELSE 'blend'::text
        END) AS style,
        CASE
            WHEN il.style IS NOT NULL THEN 'index'::text
            ELSE 'composite'::text
        END AS style_source,
        CASE
            WHEN il.style IS NOT NULL THEN 'high'::text
            WHEN sc.value_score >= 0.29::double precision THEN 'moderate'::text
            ELSE 'low'::text
        END AS style_confidence
   FROM scored sc
     LEFT JOIN index_label il ON il.security_id = sc.security_id;
