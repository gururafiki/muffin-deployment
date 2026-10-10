-- THE STOCK PAGE SAYS WHICH CURRENCY EACH NUMBER IS IN: THE CAP IN ITS OWN, THE PRICE IN THE ONE
-- YAHOO QUOTES THE LINE IN.
--
-- WHY. The stock page labelled both its price and its market cap with `security.currency_code`.
-- For many foreign listings that column held the REPORTING currency (VOD.L EUR, 0992.HK USD,
-- CSU.TO USD: Yahoo's `financialCurrency`, written by the edge's `writeCurrencyFor`), while the
-- price is in the quote currency (GBp, HKD, CAD) and the cap in the quote currency's unit.
--
-- THE QUOTE CURRENCY IS OBSERVED, AND THE PRICE LANE IS ITS ONE WRITER (decided 2026-10-10, umbrella
-- docs/specs/2026-10-10-yahoo-company-data.md). Since 2026-10-10 the price lane labels every bar
-- with the currency Yahoo's chart states for the line it prices (`meta.currency`, mapped explicitly:
-- GBp to GBX, ZAc to ZAC). `derive_security_price_span`, which already reads each security's newest
-- bar, now records that bar's label in `security_price_span.quote_currency`. A newest bar with no
-- label (an unknown code, or a unit change in progress) records none.
--
-- IT FILLS AS THE PRICE LANE VISITS, NOT FROM THE PAST. The span asset re-derives the securities
-- whose history was materialised since its last run, and every such history is now built from
-- chart documents. Bars written before 2026-10-10 still carry the old lane's guessed label, which
-- for Tel Aviv and Johannesburg was a hundred times out (agorot read as shekels), so no backfill
-- from them: a security's quote currency appears at its next visit, within a rotation (about
-- five nights).
--
-- `security_currency` prefers it, then the legacy listing, then the security, and says which
-- (`source = 'price'`). `security_current` and `instrument_current` append `quote_currency` from
-- it, and `market_cap_currency` for the cap, which now comes from `security_fundamentals` where the
-- company lane has written one (`20261010200000`). The app labels each number by its own column in
-- a muffin-ui change after this deploys. Appended, so `create or replace` keeps every grant.

alter table market.security_price_span
  add column if not exists quote_currency text references market.currency (code);
comment on column market.security_price_span.quote_currency is
  'The currency of the newest bar: what Yahoo quotes the priced line in, as the price lane observed '
  'it. Null when that bar carries no label. The one writer of a security''s quote currency.';

create or replace function market.derive_security_price_span(p_security_ids uuid[])
 returns jsonb
 language plpgsql
 set search_path to 'market', 'pg_catalog', 'pg_temp'
as $function$
declare
  v_asked   integer;
  v_written integer;
  v_empty   integer;
begin
  -- DISTINCT, because an upsert that meets one key twice fails the whole statement (SQLSTATE
  -- 21000), and a caller assembling ids from several materialisations can repeat one. And only
  -- securities that exist: an id deleted since its partition ran would otherwise fail the foreign
  -- key and take the batch with it.
  with asked as (
    select distinct a.id as security_id
      from unnest(p_security_ids) as a(id)
     where exists (select 1 from market.security s where s.security_id = a.id)
  ),
  -- Two index probes per security, not a scan: the primary key is (security_id, trade_date) in
  -- every yearly partition, so each end is a `limit 1` down that index. The newest bar also brings
  -- its label, the quote currency the price lane observed.
  span as (
    select a.security_id, f.trade_date as first_date, l.trade_date as last_date,
           l.currency_code as quote_currency
      from asked a
      left join lateral (select b.trade_date from market.price_bar b
                          where b.security_id = a.security_id
                          order by b.trade_date limit 1) f on true
      left join lateral (select b.trade_date, b.currency_code from market.price_bar b
                          where b.security_id = a.security_id
                          order by b.trade_date desc limit 1) l on true
  ),
  written as (
    insert into market.security_price_span as ps
      (security_id, first_date, last_date, quote_currency, updated_at)
    select security_id, first_date, last_date, quote_currency, now() from span
    on conflict (security_id) do update
       set first_date     = excluded.first_date,
           last_date      = excluded.last_date,
           quote_currency = excluded.quote_currency,
           updated_at     = excluded.updated_at
     -- Cheap to re-run: an unchanged span is not rewritten.
     where (ps.first_date, ps.last_date, ps.quote_currency)
           is distinct from (excluded.first_date, excluded.last_date, excluded.quote_currency)
    returning 1
  )
  select (select count(*) from asked),
         (select count(*) from written),
         (select count(*) from span where first_date is null)
    into v_asked, v_written, v_empty;

  return jsonb_build_object('asked', v_asked, 'written', v_written, 'without_bars', v_empty);
end;
$function$;

create or replace view market.security_currency as
select s.security_id,
       coalesce(ps.quote_currency, pl.currency_code, s.currency_code) as currency_code,
       case when ps.quote_currency is not null then 'price'::text
            when pl.currency_code is not null then 'listing'::text
            when s.currency_code is not null then 'security'::text
            else null::text end as source,
       pl.exch_code as venue
  from market.security s
  left join market.listing pl on pl.security_id = s.security_id and pl.is_primary
  left join market.security_price_span ps on ps.security_id = s.security_id;

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
        END AS market_cap_currency,
    cur.currency_code AS quote_currency
   FROM market.security s
     LEFT JOIN market.security_fundamentals f ON f.security_id = s.security_id
     LEFT JOIN market.security_currency cur ON cur.security_id = s.security_id
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
        END AS market_cap_currency,
    COALESCE(s.quote_currency, i.currency) AS quote_currency
   FROM market.instruments i
     LEFT JOIN market.security_current s ON s.security_id = i.security_id;
