do $$
declare k char;
begin
  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_news';
  if k = 'm' then execute 'drop materialized view if exists market.security_news cascade';
  elsif k = 'v' then execute 'drop view if exists market.security_news cascade';
  end if;
end $$;
create view market.security_news as
SELECT ns.security_id,
    sym.symbol,
    a.url,
    a.published_at,
    a.title,
    a.source,
    a.summary,
    ns.source_code
   FROM market.news_security ns
     JOIN market.news_article a ON a.url = ns.url
     JOIN market.security_symbol sym ON sym.security_id = ns.security_id;
