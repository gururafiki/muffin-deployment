-- NEWS: ONE ARTICLE, MANY SECURITIES, AND A WINDOW THAT ACTUALLY CLOSES.
--
-- WHY THIS IS A TEST. Measured across 20 symbols, 200 rows came back as 178 DISTINCT articles —
-- 11% are shared, and a market-wide story is attached to hundreds of tickers. Storing per
-- (article, security) is not merely wasteful: the copies are free to drift apart, so two stock
-- pages can show the same URL with different summaries.
--
-- And retention is the whole design question. The provider reaches back about a month, so a weekly
-- refresh adds roughly a quarter of a fresh set each time. Unbounded, that compounds for ever for
-- data whose value decays in days — and nothing about it looks wrong until the table is enormous.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZU','Newsland','ZU',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000010001', 'T100 One', 'equity', 'ZU'),
  ('00000000-0000-0000-0000-000000010002', 'T100 Two', 'equity', 'ZU')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T100A', '00000000-0000-0000-0000-000000010001', 'yfinance'),
  ('ticker', 'T100B', '00000000-0000-0000-0000-000000010002', 'yfinance')
on conflict (kind_code, value) do nothing;

do $$
declare n integer; s1 text; s2 text;
begin
  -- A market-wide story returned for BOTH securities, plus an old one.
  insert into market.news_article (url, published_at, title, source, summary) values
    ('https://example.test/fed-raises-rates', now() - interval '2 days',
     'The Fed raised rates', 'Test Wire', 'A single summary, stored once.'),
    ('https://example.test/ancient', now() - interval '200 days',
     'Something from last year', 'Test Wire', 'Old news.');
  insert into market.news_security (url, security_id, source_code) values
    ('https://example.test/fed-raises-rates', '00000000-0000-0000-0000-000000010001', 'yfinance'),
    ('https://example.test/fed-raises-rates', '00000000-0000-0000-0000-000000010002', 'yfinance'),
    ('https://example.test/ancient',          '00000000-0000-0000-0000-000000010001', 'yfinance');

  -- 1. ONE ARTICLE ROW, TWO SECURITIES. Per-security storage would make this 2 and let the
  --    summaries drift.
  select count(*) into n from market.news_article where url = 'https://example.test/fed-raises-rates';
  if n <> 1 then raise exception 'a shared article is stored % times', n; end if;

  select count(*) into n from market.news_security where url = 'https://example.test/fed-raises-rates';
  if n <> 2 then raise exception 'a shared article links to % securities, expected 2', n; end if;

  -- 2. AND BOTH SECURITIES SEE THE SAME TEXT — the property the shared row exists to guarantee.
  select summary into s1 from market.security_news
   where security_id = '00000000-0000-0000-0000-000000010001' and url = 'https://example.test/fed-raises-rates';
  select summary into s2 from market.security_news
   where security_id = '00000000-0000-0000-0000-000000010002' and url = 'https://example.test/fed-raises-rates';
  if s1 is distinct from s2 or s1 is null then
    raise exception 'two securities see different text for one article (% vs %)', s1, s2;
  end if;

  -- 3. THE WINDOW CLOSES. Without this the table only ever grows.
  select market.prune_news(90) into n;
  if n <> 1 then raise exception 'prune removed % articles, expected the one 200 days old', n; end if;

  select count(*) into n from market.news_article where url = 'https://example.test/ancient';
  if n <> 0 then raise exception 'the old article survived the prune'; end if;

  -- 4. AND ITS LINKS GO WITH IT. An orphaned link is a row pointing at nothing, and the view's
  --    inner join would hide it — so it would never be noticed, only counted.
  select count(*) into n from market.news_security where url = 'https://example.test/ancient';
  if n <> 0 then
    raise exception '% orphaned links survived — the cascade is what makes pruning the article sufficient', n;
  end if;

  -- 5. THE RECENT ONE IS UNTOUCHED. A prune that takes everything passes 3 and 4 perfectly.
  select count(*) into n from market.news_article where url = 'https://example.test/fed-raises-rates';
  if n <> 1 then raise exception 'the prune removed a recent article'; end if;

  -- 6. THE LINK RECORDS WHO MADE IT. yfinance returned a Waymo story under AAPL, so this is an
  --    attribution and not a curated relationship — a UI that drops it starts asserting more than
  --    the data supports.
  select count(*) into n from market.news_security
   where url = 'https://example.test/fed-raises-rates' and source_code = 'yfinance';
  if n <> 2 then raise exception 'the provider attribution is missing from % of 2 links', 2 - n; end if;
end $$;

rollback;

\echo 'ok: an article is stored once, shared across securities, and the retention window closes'
