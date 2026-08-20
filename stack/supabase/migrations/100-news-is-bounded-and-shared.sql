-- COMPANY NEWS: SHARED BETWEEN SECURITIES, BOUNDED IN TIME, AND HONEST ABOUT ITS ASSOCIATION.
--
-- Measured 2026-08-20 across 20 symbols spanning six markets: 200 rows came back as **178 distinct
-- articles** — 11% are shared between securities — at **555 bytes** each once the redundant field
-- is dropped, covering 2026-07-23 .. 2026-08-20. Every symbol returned exactly 10.
--
-- Three things follow from those numbers.
--
-- ── AN ARTICLE IS AN ENTITY, NOT A COLUMN ON A SECURITY ─────────────────────────────────────
--
-- 11% shared is small but not negligible, and it only grows as the universe does: a single "the
-- Fed raised rates" piece is attached to hundreds of tickers. Storing the article once and joining
-- is the difference between one row and hundreds of copies whose summaries can drift apart.
--
-- ── `text` IS BYTE-IDENTICAL TO `summary` ───────────────────────────────────────────────────
--
-- In every one of the 200 rows measured. Storing both would double the table for nothing, so only
-- `summary` is kept. Checked rather than assumed, because "they look similar" would not justify
-- discarding a field.
--
-- ── AND THE ASSOCIATION IS LOOSE, SO THE TABLE SAYS SO ──────────────────────────────────────
--
-- The top story returned for AAPL was about Waymo building an AI chip — a real article, genuinely
-- returned under Apple's symbol, and not about Apple. That is what the provider means by "company
-- news", so `news_security` records WHICH PROVIDER made the link rather than presenting it as a
-- curated relationship. A UI that says "related news" is telling the truth; one that says "news
-- about this company" is not.
--
-- ── RETENTION IS THE WHOLE DESIGN QUESTION ──────────────────────────────────────────────────
--
-- The provider only reaches back about a month, so a weekly refresh adds roughly a quarter of a
-- fresh set each time. Unbounded, that compounds for ever for data whose value decays in days.
-- 90 days is kept: long enough that a stock page has depth, short enough that the table settles
-- rather than grows. The resource prunes; the constant lives in one place.

create table if not exists market.news_article (
  -- THE URL IS THE IDENTITY. The provider also sends an `id`, and measured they are 1:1 (178
  -- distinct ids, 178 distinct urls) — but a provider's own id is a provider's own id, and the URL
  -- is what makes the same article the same article if a second source is ever added.
  url          text primary key,
  published_at timestamptz not null,
  title        text not null,
  source       text,
  summary      text,
  first_seen   timestamptz not null default now()
);

create index if not exists news_article_published_idx
  on market.news_article (published_at desc);

comment on table market.news_article is
  'One row per article, keyed on its URL. 11% of articles are returned for more than one security (measured), and a market-wide story is attached to hundreds — storing it once is the difference between one row and hundreds of copies free to drift apart. `text` is not stored: it was byte-identical to `summary` in all 200 rows measured.';

create table if not exists market.news_security (
  url         text not null references market.news_article (url) on delete cascade,
  security_id uuid not null references market.security (security_id) on delete cascade,
  -- WHICH PROVIDER MADE THE LINK. yfinance's association is loose — the top story returned for
  -- AAPL was about Waymo — so this records an attribution rather than asserting a relationship.
  source_code text not null references market.data_source (code),
  primary key (url, security_id)
);

create index if not exists news_security_by_security_idx
  on market.news_security (security_id);

comment on table market.news_security is
  'Which securities a provider returned an article for. An ATTRIBUTION, not a curated relationship: yfinance returned a Waymo story under AAPL. A UI saying "related news" is honest; one saying "news about this company" is not.';

-- ── the serving view ─────────────────────────────────────────────────────────────────────────
drop view if exists market.security_news;

create view market.security_news as
select
  ns.security_id,
  sym.symbol,
  a.url,
  a.published_at,
  a.title,
  a.source,
  a.summary,
  ns.source_code
from market.news_security ns
join market.news_article a  on a.url = ns.url
join market.security_symbol sym on sym.security_id = ns.security_id;

comment on view market.security_news is
  'Articles a provider returned for a security, newest first when ordered. The association is the PROVIDER''S — see news_security.';

grant select on market.news_article, market.news_security, market.security_news
  to anon, authenticated, service_role;
grant insert, update, delete on market.news_article, market.news_security to service_role;

alter table market.news_article  enable row level security;
alter table market.news_security enable row level security;
do $$ begin
  create policy news_article_public_read on market.news_article for select using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy news_security_public_read on market.news_security for select using (true);
exception when duplicate_object then null; end $$;

-- ── retention, as a function so the constant lives in one place ─────────────────────────────
create or replace function market.prune_news(p_days integer default 90)
returns integer
language plpgsql
as $$
declare v_deleted integer := 0;
begin
  -- The join rows go with the article via `on delete cascade`, so pruning the article is enough.
  -- Deleting the LINKS first and the articles second would leave orphans on any partial failure.
  delete from market.news_article
   where published_at < now() - make_interval(days => p_days);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function market.prune_news(integer) is
  'Drops articles older than the retention window; the security links cascade. The provider only reaches back about a month, so a weekly refresh adds a fresh quarter-set each time — unbounded, that compounds for ever for data whose value decays in days.';

revoke execute on function market.prune_news(integer) from public;
grant execute on function market.prune_news(integer) to service_role;

-- ── the backlog ──────────────────────────────────────────────────────────────────────────────
alter table market.security add column if not exists news_fetched_at timestamptz;

drop view if exists market.pending_news;

create view market.pending_news as
select
  s.security_id,
  sym.symbol,
  coalesce(ps.symbol, sym.symbol) as fetch_symbol,
  coalesce(max(h.weight), 0)      as best_weight
from market.security s
join market.security_symbol sym on sym.security_id = s.security_id
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  -- Keyed on when we last ASKED. News has no "done" state — a security always has more news
  -- tomorrow — so an anti-join over rows would re-ask everything for ever.
  and (s.news_fetched_at is null or s.news_fetched_at < now() - interval '7 days')
group by s.security_id, sym.symbol, coalesce(ps.symbol, sym.symbol)
order by best_weight desc, s.security_id;

comment on view market.pending_news is
  'Equities whose news has not been read in 7 days, heaviest fund holding first. Keyed on when we ASKED because news has no "done" state — an anti-join over existing rows would re-ask the whole universe for ever.';

grant select on market.pending_news to service_role;

notify pgrst, 'reload schema';
