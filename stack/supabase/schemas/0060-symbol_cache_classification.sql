do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'symbol_cache_classification';
  if k = 'm' then execute 'drop materialized view if exists market.symbol_cache_classification cascade';
  elsif k = 'v' then execute 'drop view if exists market.symbol_cache_classification cascade';
  end if;
end $$;
create view market.symbol_cache_classification as
SELECT column_name,
    symbol_keyed,
    reason
   FROM ( VALUES ('industry_missing_at'::text,true,'yfinance profile fetched by symbol'::text), ('profile_missing_at'::text,true,'yfinance profile fetched by symbol'::text), ('performance_missing_at'::text,true,'historical bars fetched by symbol'::text), ('fundamentals_missing_at'::text,true,'metrics fetched by symbol'::text), ('statements_missing_at'::text,true,'statements fetched by symbol'::text), ('prices_missing_at'::text,true,'daily bars fetched by symbol'::text), ('quarters_missing_at'::text,true,'quarterly statements fetched by the PRICED symbol'::text), ('provider_country_missing_at'::text,true,'yfinance profile fetched by symbol'::text), ('corporate_actions_missing_at'::text,true,'Tiingo EOD fetched by the US ticker'::text), ('dividends_missing_at'::text,true,'yfinance dividends fetched by the PRICED symbol'::text), ('price_history_missing_at'::text,true,'weekly history fetched by the PRICED symbol'::text), ('daily_history_missing_at'::text,true,'deep daily history fetched by the PRICED symbol'::text), ('share_stats_missing_at'::text,true,'share statistics fetched by the PRICED symbol'::text), ('estimates_missing_at'::text,true,'analyst consensus fetched by the PRICED symbol'::text), ('profile_detail_missing_at'::text,true,'yfinance profile fetched by symbol'::text), ('figi_missing_at'::text,false,'OpenFIGI asked for the ISIN, not the symbol'::text), ('local_symbol_missing_at'::text,false,'keyed on ISIN/FIGI, not the symbol'::text), ('yahoo_symbol_missing_at'::text,false,'the resolver''s own flag — clearing it here would loop'::text), ('statement_currency_missing_at'::text,false,'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'::text), ('xbrl_missing_at'::text,false,'company facts are asked for by CIK; a new provider symbol says nothing about the filer'::text), ('wikidata_missing_at'::text,false,'Wikidata is asked for by ISIN; a corrected provider symbol says nothing about a Wikidata entity, and clearing it would re-ask a public endpoint for an answer already held'::text)) t(column_name, symbol_keyed, reason);
