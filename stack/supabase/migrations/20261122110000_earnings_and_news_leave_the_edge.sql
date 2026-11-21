-- EARNINGS AND NEWS LEAVE THE EDGE: the earnings keys carry the provider, the news read stops
-- scanning the universe, and three resources retire (Phase 6b step 4, umbrella
-- docs/specs/2026-11-21-macro-and-events.md).
--
-- RETIRES: earnings-calendar
-- RETIRES: earnings-history
-- RETIRES: security-news
--
-- THE REPLACEMENTS ARE DAGSTER LANES (muffin-ingest#187, #188):
--   * `raw_nasdaq_earnings` → `nasdaq_earnings`: nasdaq's calendar one date per request, asked
--     directly. openbb crashes on nasdaq's `data: null` for a day with no reports, which is what had
--     stalled `earnings-history` on 2016-06-28..30 since 2026-09-06 while it reported `ok`;
--   * `yahoo_earnings`: Yahoo's next date and last four quarters from the summaries the company lane
--     already stores, global where nasdaq is US-only;
--   * `raw_yahoo_news` → `company_news`: Yahoo's per-company RSS headlines. openbb's yfinance news
--     route has answered 204 since 2026-10-01, so `security-news` stored nothing for seven weeks
--     while stamping every company as fetched.
--
-- 1. THE KEYS CARRY THE PROVIDER. Nasdaq and Yahoo state the same report and the same quarter, and
--    under `(symbol, report_date)` and `(security_id, period_ending)` the second writer would
--    overwrite the first. Measured 2026-11-21 on 1,097 quarters both sources hold: actual EPS agrees
--    on 65%; the rest are ADR ratios and other EPS bases. Both are kept, and the serving views choose
--    one source per company (20261122100000). No duplicate exists under the new keys (measured: 0 of
--    8,193 and 0 of 105,765), and the index builds take under a second.
--
-- 2. THE NEWS READ JOINS `symbol_security`, not `security_symbol`. The app reads `security_news` by
--    symbol, and `security_symbol` resolves every security's symbol through per-row subplans to find
--    one: 30,131 securities, 234-259 ms for AAPL, SAP.DE and 7203.T as anon, and a plan that walks
--    articles newest first, which grows with every week the feed adds. The same fix as
--    `security_statement_current` (muffin-deployment#447): the materialised map holds the same
--    rows, indexed on the symbol, and only its freshness differs. The columns are unchanged, so
--    `create or replace` keeps the grants.
--
-- 3. THE ROTATION ROWS ARE DISABLED, and `market-refresh` answers 410 for the three, naming the
--    lane that replaced each. `pending_news`, `earnings_history_cursor`, `security.news_fetched_at`
--    and `security_earnings_surprise` stay until the contract step (Phase 6b step 7).

alter table market.earnings_calendar drop constraint earnings_calendar_pkey;
alter table market.earnings_calendar
  add constraint earnings_calendar_pkey primary key (source_code, symbol, report_date);

alter table market.security_eps_history drop constraint security_eps_history_pkey;
alter table market.security_eps_history
  add constraint security_eps_history_pkey primary key (security_id, period_ending, source_code);

create or replace view market.security_news as
select ns.security_id,
       sym.symbol,
       a.url,
       a.published_at,
       a.title,
       a.source,
       a.summary,
       ns.source_code
  from market.news_security ns
  join market.news_article a on a.url = ns.url
  join market.symbol_security sym on sym.security_id = ns.security_id;

update market.cron_resource
   set enabled = false
 where resource in ('earnings-calendar', 'earnings-history', 'security-news');
