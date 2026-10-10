-- A MARKET CAP CARRIES ITS OWN CURRENCY, AND EVERY READER THAT CONVERTS OR LABELS ONE USES IT.
--
-- WHY. Phase 4, decision 12 (umbrella docs/specs/2026-10-10-yahoo-company-data.md). The cap lived on
-- `security.market_cap`, written once by the edge from openbb's metrics response (median as_of
-- 2026-08-13) and never refreshed, with no currency of its own. Every reader paired it with
-- `security.currency_code`, which `writeCurrencyFor` filled with that response's `currency`, and
-- that field is Yahoo's `financialCurrency`, the REPORTING currency (measured 2026-10-10 against
-- openbb-api: VOD.L EUR, 0992.HK USD, CSU.TO USD). A cap is stated in the QUOTE currency's unit:
-- VOD.L 27,418,447,872 in pounds against a 118.35p price, BHP.AX in AUD although it reports in USD.
-- So `security_market_cap_usd`, which feeds cap bands, style, peers and the cap-weighted
-- aggregates, converted a stale number at another currency's rate.
--
-- THE CAP NOW LIVES WITH THE OTHER YAHOO FACTS, AND IS STORED ONLY WITH ITS CURRENCY: two columns on
-- `security_fundamentals`, written weekly by the Dagster company lane, and a check that one is never
-- present without the other. Nothing can pair a fresh cap with a guessed label.
--
-- THE OLD PAIR IS THE FALLBACK, AND ONLY WHERE NOTHING NEWER EXISTS. Until the lane first visits a
-- security, every reader returns exactly what it returned before. `security.market_cap` and
-- `market_cap_at` stay as the backup until the contract step, which has a deferred note and a date.
--
-- READERS MOVED HERE:
--   `security_market_cap_usd`  style, the facets' cap band, peers, `aggregate_performance` and the
--                              screener's USD filter. Appends `cap_source`, so the transition can be
--                              counted ('fundamentals' or 'security').
--   `security_current`, `instrument_current`  the stock page's "Market cap". Each APPENDS
--                              `market_cap_currency`, the currency of the `market_cap` beside it. The
--                              app labels the cap by it in a muffin-ui change that ships after this.
-- Appended, not inserted, so `create or replace` keeps every grant and every dependent view.
-- NOT MOVED: `sector_constituents`, which orders a country page by the legacy cap. It was the
-- 14-second anon timeout of 2026-09-25, so it moves with the contract step, where its timing is
-- re-measured (docs/deferred/2026-10-10-the-native-cap-readers-left-on-the-legacy-column.md).

alter table market.security_fundamentals
  add column if not exists market_cap numeric,
  add column if not exists market_cap_currency text references market.currency (code);

alter table market.security_fundamentals
  drop constraint if exists security_fundamentals_cap_has_a_currency;
alter table market.security_fundamentals
  add constraint security_fundamentals_cap_has_a_currency
  check ((market_cap is null) = (market_cap_currency is null));

comment on column market.security_fundamentals.market_cap is
  'Market capitalisation as Yahoo states it, in market_cap_currency. Written by the Dagster company '
  'lane; null until its first visit, when readers fall back to security.market_cap.';
comment on column market.security_fundamentals.market_cap_currency is
  'The currency market_cap is stated in: the quote currency''s unit, so a pence listing is '
  'capitalised in pounds. Never the reporting currency (BHP.AX reports in USD, is capitalised in AUD).';

create or replace view market.security_market_cap_usd as
select s.security_id,
       c.native as market_cap_native,
       c.currency as currency_code,
       case
         when c.native is null then null::numeric
         when c.currency = 'USD'::text then c.native
         else c.native * fx.usd_per_unit
       end as market_cap_usd,
       fx.as_of as fx_as_of,
       c.source as cap_source
  from market.security s
  left join market.security_fundamentals f on f.security_id = s.security_id
  cross join lateral (
    select case when f.market_cap is not null then f.market_cap else s.market_cap end as native,
           case when f.market_cap is not null then f.market_cap_currency else s.currency_code end
             as currency,
           case when f.market_cap is not null then 'fundamentals'::text
                when s.market_cap is not null then 'security'::text end as source) c
  left join market.fx_rate_current fx on fx.currency_code = c.currency;

create or replace view market.security_current as
SELECT s.security_id,
    s.name,
    s.security_type_code,
    COALESCE(s.provider_country_iso2, s.country_iso2) AS country_iso2,
    s.currency_code,
    s.is_tradeable,
    COALESCE(f.market_cap, s.market_cap) AS market_cap,
    sym.symbol,
    isin.value AS isin,
    i.name AS issuer_name,
    c.name AS country_name,
    ( SELECT tn.code
           FROM market.security_taxonomy st
             JOIN market.taxonomy_node tn ON tn.node_id = st.node_id AND tn.taxonomy_id = 'muffin'::text AND tn.level = 1
             JOIN market.data_source ds ON ds.code = st.source_code
          WHERE st.security_id = s.security_id
          ORDER BY ds.priority DESC, st.as_of DESC
         LIMIT 1) AS sector_id,
    ( SELECT n.name
           FROM market.security_taxonomy st2
             JOIN market.taxonomy_node n ON n.node_id = st2.node_id AND n.taxonomy_id = 'muffin'::text AND n.level = 2 AND n.parent_id = (( SELECT tn.node_id
                   FROM market.security_taxonomy st_sec
                     JOIN market.taxonomy_node tn ON tn.node_id = st_sec.node_id AND tn.taxonomy_id = 'muffin'::text AND tn.level = 1
                     JOIN market.data_source ds_sec ON ds_sec.code = st_sec.source_code
                  WHERE st_sec.security_id = s.security_id
                  ORDER BY ds_sec.priority DESC, st_sec.as_of DESC
                 LIMIT 1))
             JOIN market.data_source ds2 ON ds2.code = st2.source_code
          WHERE st2.security_id = s.security_id
          ORDER BY ds2.priority DESC, st2.as_of DESC
         LIMIT 1) AS industry,
    ( SELECT n.code
           FROM market.security_taxonomy st2
             JOIN market.taxonomy_node n ON n.node_id = st2.node_id AND n.taxonomy_id = 'muffin'::text AND n.level = 2 AND n.parent_id = (( SELECT tn.node_id
                   FROM market.security_taxonomy st_sec
                     JOIN market.taxonomy_node tn ON tn.node_id = st_sec.node_id AND tn.taxonomy_id = 'muffin'::text AND tn.level = 1
                     JOIN market.data_source ds_sec ON ds_sec.code = st_sec.source_code
                  WHERE st_sec.security_id = s.security_id
                  ORDER BY ds_sec.priority DESC, st_sec.as_of DESC
                 LIMIT 1))
             JOIN market.data_source ds2 ON ds2.code = st2.source_code
          WHERE st2.security_id = s.security_id
          ORDER BY ds2.priority DESC, st2.as_of DESC
         LIMIT 1) AS industry_code,
    s.country_iso2 AS filed_country_iso2,
    s.provider_country_iso2,
        CASE
            WHEN f.market_cap IS NOT NULL THEN f.market_cap_currency
            WHEN s.market_cap IS NOT NULL THEN s.currency_code
            ELSE NULL::text
        END AS market_cap_currency
   FROM market.security s
     LEFT JOIN market.security_fundamentals f ON f.security_id = s.security_id
     LEFT JOIN market.security_symbol sym ON sym.security_id = s.security_id
     LEFT JOIN market.security_identifier isin ON isin.security_id = s.security_id AND isin.kind_code = 'isin'::text
     LEFT JOIN market.issuer i ON i.issuer_id = s.issuer_id
     LEFT JOIN market.countries c ON c.iso2 = COALESCE(s.provider_country_iso2, s.country_iso2);

create or replace view market.instrument_current as
SELECT i.symbol,
    COALESCE(i.name, s.name) AS name,
    i.asset_type,
    i.priced,
    i.sort_order,
    i.price_symbol,
    i.security_id,
    COALESCE(s.sector_id, i.sector_id) AS sector_id,
    COALESCE(s.industry, i.industry) AS industry,
    COALESCE(s.country_name, i.country) AS country,
    COALESCE(s.market_cap, i.market_cap) AS market_cap,
    COALESCE(s.currency_code, i.currency) AS currency,
    i.provider_sector,
    i.updated_at,
        CASE
            WHEN s.market_cap IS NOT NULL THEN s.market_cap_currency
            ELSE i.currency
        END AS market_cap_currency
   FROM market.instruments i
     LEFT JOIN market.security_current s ON s.security_id = i.security_id;
