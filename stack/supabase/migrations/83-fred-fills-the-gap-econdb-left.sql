-- FRED FILLS THE GAP ECONDB LEFT, AND ITS KEY WAS ALREADY CONFIGURED.
--
-- econdb has no free programmatic tier (confirmed by the operator) and this node is 403'd from its
-- free temporary-token endpoint besides — see migration 82. Routing around that block to take free
-- data was rejected; the 403 is a deliberate signal even if it is blanket cloud-IP filtering.
--
-- FRED needs no new credential: `FRED_API_KEY` is already set on openbb-api, and
-- `economy/fred_series` serves international macro by explicit series id.
--
-- ── EVERY ID BELOW WAS DRIVEN BEFORE IT WAS SEEDED (2026-08-19) ──────────────────────────────
--
-- Because FRED RETIRES SERIES, and a retired id is indistinguishable from a working one until you
-- ask: `JPNCPIALLMINMEI` returns 0 rows. A candidate matrix of 42 was driven and reported as three
-- separate outcomes — live / empty / errored, never merged, since "the provider has nothing" and
-- "the request failed" are different facts:
--
--   LIVE 37    EMPTY 5    ERROR 0
--
-- Only the 37 that returned rows are seeded. The 5 that did not are listed at the foot of this
-- file so nobody re-adds them believing they were overlooked.
--
-- ── THE COUNTRY CODE IS TWO LETTERS, NOT ISO3 ────────────────────────────────────────────────
--
-- The first matrix used ISO3 and every single one of 42 came back empty. That looked exactly like
-- a provider outage — and my probe could not tell the difference, because it swallowed exceptions
-- into an empty list, which is the throw-vs-empty defect this codebase has hit six times. Measured
-- side by side afterwards: `LRHUTTTTDEM156S` returns 18 rows (3.9), `LRHUTTTTDEUM156S` returns 0.
--
-- Values are already PERCENT here (4.4 = 4.4%), unlike OECD's fractions — hence
-- value_is_fraction = false. Sanity-checked on seeding: US unemployment 4.4, Spain 10.1,
-- Japan 2.5; 10y yields US 4.47, Switzerland 0.31, Mexico 9.45.

insert into market.macro_indicator
  (code, name, category, route, provider, params, country_iso2, provider_country, frequency, unit, value_is_fraction, sort_order)
select v.code, v.name, v.category, v.route, v.provider, v.params::jsonb, v.iso2, v.pc, v.freq, v.unit, v.frac, v.ord
from (values
  ('us-unemployment-fred', 'US unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTUSM156S"}', 'US', null, 'monthly', 'percent', false, 30),
  ('de-unemployment-fred', 'Germany unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTDEM156S"}', 'DE', null, 'monthly', 'percent', false, 30),
  ('jp-unemployment-fred', 'Japan unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTJPM156S"}', 'JP', null, 'monthly', 'percent', false, 30),
  ('gb-unemployment-fred', 'UK unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTGBM156S"}', 'GB', null, 'monthly', 'percent', false, 30),
  ('fr-unemployment-fred', 'France unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTFRM156S"}', 'FR', null, 'monthly', 'percent', false, 30),
  ('ca-unemployment-fred', 'Canada unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTCAM156S"}', 'CA', null, 'monthly', 'percent', false, 30),
  ('it-unemployment-fred', 'Italy unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTITM156S"}', 'IT', null, 'monthly', 'percent', false, 30),
  ('es-unemployment-fred', 'Spain unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTESM156S"}', 'ES', null, 'monthly', 'percent', false, 30),
  ('au-unemployment-fred', 'Australia unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTAUM156S"}', 'AU', null, 'monthly', 'percent', false, 30),
  ('kr-unemployment-fred', 'South Korea unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTKRM156S"}', 'KR', null, 'monthly', 'percent', false, 30),
  ('mx-unemployment-fred', 'Mexico unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTMXM156S"}', 'MX', null, 'monthly', 'percent', false, 30),
  ('nl-unemployment-fred', 'Netherlands unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTNLM156S"}', 'NL', null, 'monthly', 'percent', false, 30),
  ('se-unemployment-fred', 'Sweden unemployment rate', 'labour', '/api/v1/economy/fred_series', 'fred', '{"symbol":"LRHUTTTTSEM156S"}', 'SE', null, 'monthly', 'percent', false, 30),
  ('us-10y-yield-fred', 'US 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01USM156N"}', 'US', null, 'monthly', 'percent', false, 40),
  ('de-10y-yield-fred', 'Germany 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01DEM156N"}', 'DE', null, 'monthly', 'percent', false, 40),
  ('jp-10y-yield-fred', 'Japan 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01JPM156N"}', 'JP', null, 'monthly', 'percent', false, 40),
  ('gb-10y-yield-fred', 'UK 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01GBM156N"}', 'GB', null, 'monthly', 'percent', false, 40),
  ('fr-10y-yield-fred', 'France 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01FRM156N"}', 'FR', null, 'monthly', 'percent', false, 40),
  ('ca-10y-yield-fred', 'Canada 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01CAM156N"}', 'CA', null, 'monthly', 'percent', false, 40),
  ('it-10y-yield-fred', 'Italy 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01ITM156N"}', 'IT', null, 'monthly', 'percent', false, 40),
  ('es-10y-yield-fred', 'Spain 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01ESM156N"}', 'ES', null, 'monthly', 'percent', false, 40),
  ('au-10y-yield-fred', 'Australia 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01AUM156N"}', 'AU', null, 'monthly', 'percent', false, 40),
  ('kr-10y-yield-fred', 'South Korea 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01KRM156N"}', 'KR', null, 'monthly', 'percent', false, 40),
  ('mx-10y-yield-fred', 'Mexico 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01MXM156N"}', 'MX', null, 'monthly', 'percent', false, 40),
  ('ch-10y-yield-fred', 'Switzerland 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01CHM156N"}', 'CH', null, 'monthly', 'percent', false, 40),
  ('nl-10y-yield-fred', 'Netherlands 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01NLM156N"}', 'NL', null, 'monthly', 'percent', false, 40),
  ('se-10y-yield-fred', 'Sweden 10y government bond yield', 'rates', '/api/v1/economy/fred_series', 'fred', '{"symbol":"IRLTLT01SEM156N"}', 'SE', null, 'monthly', 'percent', false, 40),
  ('us-cpi-fred', 'US inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01USM659N"}', 'US', null, 'monthly', 'percent', false, 10),
  ('de-cpi-fred', 'Germany inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01DEM659N"}', 'DE', null, 'monthly', 'percent', false, 10),
  ('gb-cpi-fred', 'UK inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01GBM659N"}', 'GB', null, 'monthly', 'percent', false, 10),
  ('fr-cpi-fred', 'France inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01FRM659N"}', 'FR', null, 'monthly', 'percent', false, 10),
  ('ca-cpi-fred', 'Canada inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01CAM659N"}', 'CA', null, 'monthly', 'percent', false, 10),
  ('it-cpi-fred', 'Italy inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01ITM659N"}', 'IT', null, 'monthly', 'percent', false, 10),
  ('es-cpi-fred', 'Spain inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01ESM659N"}', 'ES', null, 'monthly', 'percent', false, 10),
  ('ch-cpi-fred', 'Switzerland inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01CHM659N"}', 'CH', null, 'monthly', 'percent', false, 10),
  ('nl-cpi-fred', 'Netherlands inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01NLM659N"}', 'NL', null, 'monthly', 'percent', false, 10),
  ('se-cpi-fred', 'Sweden inflation', 'inflation', '/api/v1/economy/fred_series', 'fred', '{"symbol":"CPALTT01SEM659N"}', 'SE', null, 'monthly', 'percent', false, 10)
) as v(code, name, category, route, provider, params, iso2, pc, freq, unit, frac, ord)
-- JOINED, not blind-inserted: `country_iso2` is a foreign key, and a country absent from
-- market.countries would fail the whole migration rather than skip one series.
join market.countries c on c.iso2 = v.iso2
on conflict (code) do update set
  name = excluded.name, category = excluded.category, route = excluded.route,
  provider = excluded.provider, params = excluded.params,
  country_iso2 = excluded.country_iso2, provider_country = excluded.provider_country,
  frequency = excluded.frequency, unit = excluded.unit,
  value_is_fraction = excluded.value_is_fraction, sort_order = excluded.sort_order;
-- `enabled` is deliberately NOT in that update list — see migration 82.

-- DRIVEN AND EMPTY, therefore NOT seeded (re-check before adding, do not assume they were missed):
--   LRHUTTTTCHM156S  CH  unemployment
--   CPALTT01JPM659N  JP  inflation
--   CPALTT01AUM659N  AU  inflation
--   CPALTT01KRM659N  KR  inflation
--   CPALTT01MXM659N  MX  inflation

notify pgrst, 'reload schema';
