-- The app reads `security_news` by symbol, and that read must resolve ONE symbol, not every
-- security's (migration 20261122110000). On `security_symbol` it walked 30,131 securities through
-- per-row subplans: 234-259 ms as anon, growing with the news the feed adds.
--
-- A plan-shape test, like `a-one-symbol-ratio-read-reads-one-security.sql`: on a fixture every plan
-- is fast, so the guard counts the rows the read touches in `market.security`. On the
-- materialised map it touches none; on `security_symbol` it reads every security.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yahoo-rss','Yahoo RSS',50) on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code)
select ('00000000-0000-0000-0000-' || lpad(to_hex(4000 + g), 12, '0'))::uuid, 'N' || g, 'equity'
  from generate_series(1, 400) g
on conflict (security_id) do nothing;
insert into market.security_provider_symbol (security_id, provider_code, symbol)
select ('00000000-0000-0000-0000-' || lpad(to_hex(4000 + g), 12, '0'))::uuid, 'yfinance', 'N' || g
  from generate_series(1, 400) g
on conflict do nothing;

insert into market.news_article (url, published_at, title)
select 'https://x/' || g, now() - make_interval(hours => g), 'story ' || g from generate_series(1, 50) g;
insert into market.news_security (url, security_id, source_code)
select 'https://x/' || g, ('00000000-0000-0000-0000-' || lpad(to_hex(4000 + 1 + g % 5), 12, '0'))::uuid, 'yahoo-rss'
  from generate_series(1, 50) g;

refresh materialized view market.symbol_security;
analyze market.security;

do $$
declare got int; touched numeric; plan json;
begin
  select count(*) into got from market.security_news where symbol = 'N2';
  if got <> 10 then
    raise exception 'the news read must return the symbol''s own articles: got %', got;
  end if;

  set local enable_seqscan = off;
  execute 'explain (analyze, format json) select url from market.security_news '
          'where symbol = ''N2'' order by published_at desc limit 10' into plan;
  select coalesce(sum((n->>'Actual Rows')::numeric * (n->>'Actual Loops')::numeric), 0)
    into touched
    from jsonb_path_query(plan::jsonb, 'strict $.**') n
   where jsonb_typeof(n) = 'object' and n->>'Relation Name' = 'security';
  if touched > 0 then
    raise exception 'a one-symbol news read touched % security rows: it resolves every symbol', touched;
  end if;
  raise notice 'ok  a one-symbol news read resolves one symbol';
end $$;

rollback;
