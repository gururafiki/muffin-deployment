-- `jp-cpi` asks BIS, because OECD's Japan CPI ends at 2021-06.
--
-- MEASURED 2026-11-25. `jp-cpi` asked OECD's `economy/cpi` for Japan, and OECD's answer ends at
-- 2021-06, while Germany, Korea and the UK answer to 2026-09/10 in the same call. So the macro
-- lane's `macro_series_fresh` failed every day on this one series. FRED's monthly Japanese CPI
-- series (`CPALTT01JPM659N`, `JPNCPIALLMINMEI`, `CPGRLE01JPM659N`) are empty after 2023, and its
-- only current one is the World Bank's annual figure. BIS's `WS_LONG_CPI` carries Japan monthly to
-- 2026-09 (2.097902), keyless. For Germany, Korea and the US it equals OECD's year-on-year change
-- to six decimals, so it measures the same thing, stated in PERCENT where OECD states a fraction.
-- Decided by the user: BIS for Japan only.
--
-- THE ROUTE IS BIS'S OWN PATH, WITH THE DATAFLOW IN IT, and `params` holds exactly the series key
-- (`M.JP.771`: monthly, Japan, year-on-year change). `muffin_ingest.providers.bis.series_key`
-- reads both and refuses anything else.
--
-- ORDER: muffin-ingest#202 rolls first. Before it, the lane counts this row `unroutable`, which
-- costs nothing: the row has not answered since 2021.

update market.macro_indicator
   set provider = 'bis',
       route = '/api/v1/data/WS_LONG_CPI',
       params = '{"key": "M.JP.771"}'::jsonb,
       value_is_fraction = false,
       notes = 'BIS WS_LONG_CPI M.JP.771: monthly year-on-year change, in percent. OECD''s Japan '
               'CPI ends at 2021-06 (measured 2026-11-25).'
 where code = 'jp-cpi';
