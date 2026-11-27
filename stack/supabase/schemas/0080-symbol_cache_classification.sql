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
   FROM ( VALUES ('corporate_actions_missing_at'::text,true,'Tiingo EOD fetched by the US ticker'::text), ('statement_currency_missing_at'::text,false,'SEC asked by the US ticker; a new provider symbol says nothing about whether the company files'::text), ('xbrl_missing_at'::text,false,'company facts are asked for by CIK; a new provider symbol says nothing about the filer'::text), ('wikidata_missing_at'::text,false,'Wikidata is asked for by ISIN; a corrected provider symbol says nothing about a Wikidata entity, and clearing it would re-ask a public endpoint for an answer already held'::text)) t(column_name, symbol_keyed, reason);
