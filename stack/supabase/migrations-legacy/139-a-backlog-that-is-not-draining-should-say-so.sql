-- A BACKLOG THAT IS NOT DRAINING SHOULD SAY SO, AND `written` IS NOT THAT SIGNAL.
--
-- Two live stalls were found by hand on 2026-08-28, both reporting `ok: true` and both invisible
-- to every count in the system:
--
--   security-statements   `written: 240, remaining: 8668` — BYTE-IDENTICAL on five consecutive
--                         runs, while the head of its backlog already held 15-27 statements each.
--   security-eps-history  `remaining: 300`, flat, re-asking a quota it had already exhausted.
--
-- Both were found by comparing two runs by eye. `market.backlog_sample` has had the depth all
-- along; nothing computed a RATE from it, so the dashboards showed a line that was flat and no
-- alert could fire on "flat". This adds the derivative.
--
-- ── WHY A REGRESSION AND NOT A DELTA ──────────────────────────────────────────────────────────
--
-- A two-point delta across the outage this pipeline had on 2026-08-27 (nothing ran for eleven
-- hours) reports an absurd rate in whichever direction the endpoints happen to fall.
-- `regr_slope` over a window is robust to that and to one bad sample, which is the realistic case.
--
-- ── AND WHY A DRAINING BACKLOG IS NOT NECESSARILY GOOD NEWS ───────────────────────────────────
--
-- This is the rule the whole file turns on: **a backlog that empties by MARKING looks exactly like
-- one that empties by WORKING.** On 2026-08-13 `pending_industry` went to zero while ~8,300
-- securities were being negative-cached as permanently unanswerable, and every count read as
-- progress. So the drain rate is reported BESIDE the growth rate of the negative cache that
-- excludes the same securities, and a backlog draining while its cache grows at a comparable rate
-- is called out rather than congratulated.

-- ── THE PAIRING IS DATA, NOT STRING SURGERY ───────────────────────────────────────────────────
--
-- `pending_X` -> `X_missing_at` looks mechanical and is not: `pending_quarters` pairs with
-- `quarters_missing_at`, `pending_daily_history` with `daily_history_missing_at`, and
-- `pending_metrics` has no negative cache at all because it is a DRIFT COUNTER rather than a work
-- queue. This schema has been bitten three times by keying on an identifier that looked regular
-- (`composite_figi` is per country, `exchange_listing.country_iso2` is the venue's), so the map is
-- a table.
create table if not exists market.backlog_negative_cache (
  backlog        text primary key,
  missing_column text,
  note           text
);

insert into market.backlog_negative_cache (backlog, missing_column, note) values
  ('pending_industry',          'industry_missing_at',          null),
  ('pending_profile',           'profile_missing_at',           null),
  ('pending_profile_detail',    'profile_detail_missing_at',    null),
  ('pending_performance',       'performance_missing_at',       null),
  ('pending_fundamentals',      'fundamentals_missing_at',      null),
  ('pending_statements',        'statements_missing_at',        null),
  ('pending_quarters',          'quarters_missing_at',          null),
  ('pending_prices',            'prices_missing_at',            null),
  ('pending_price_history',     'price_history_missing_at',     null),
  ('pending_daily_history',     'daily_history_missing_at',     null),
  ('pending_dividends',         'dividends_missing_at',         null),
  ('pending_corporate_actions', 'corporate_actions_missing_at', null),
  ('pending_share_stats',       'share_stats_missing_at',       null),
  ('pending_local_symbol',      'local_symbol_missing_at',      null),
  ('pending_yahoo_symbol',      'yahoo_symbol_missing_at',      null),
  ('pending_ticker',            'figi_missing_at',              'keyed on the ISIN, not the symbol'),
  ('pending_xbrl',              'xbrl_missing_at',              null),
  ('pending_metrics',           null, 'a DRIFT COUNTER, not a queue: the function re-derives everything every run, so a non-zero value is expected and the TREND is the signal'),
  ('pending_ttm',               null, 'derived in SQL, no provider and therefore no negative cache'),
  ('pending_promotion',         null, 'opt-in per venue; does nothing until an operator enables one'),
  ('pending_symbol_repair',     null, 'verifies candidates against the provider; an unrepairable symbol simply stays')
on conflict (backlog) do update
  set missing_column = excluded.missing_column, note = excluded.note;

-- READ AND WRITE for service_role, because `every-table-is-reachable.sql` asserts it and is right
-- to: `security_price` once shipped with the views granted and the TABLE forgotten, so the
-- resource could not write a single row while every migration pass was green. The migration tests
-- run as superuser and cannot see a grant problem at all.
grant select on market.backlog_negative_cache to metrics_ro, anon;
grant select, insert, update, delete on market.backlog_negative_cache to service_role;

alter table market.backlog_negative_cache enable row level security;
do $$ begin
  drop policy if exists backlog_negative_cache_read on market.backlog_negative_cache;
  create policy backlog_negative_cache_read on market.backlog_negative_cache
    for select to anon, authenticated, metrics_ro using (true);
end $$;

-- ── THE RATE ──────────────────────────────────────────────────────────────────────────────────
drop view if exists market.backlog_drain;
create view market.backlog_drain as
with obs as (
  select backlog, sampled_at, depth
    from market.backlog_sample
   where sampled_at > now() - interval '7 days'
     and error is null and depth is not null
),
fit as (
  select backlog,
         count(*)                                                        as samples,
         -- Depth per DAY. Negative is draining.
         regr_slope(depth, extract(epoch from sampled_at) / 86400.0)     as per_day
    from obs group by backlog
),
latest as (
  select distinct on (backlog) backlog, depth, sampled_at
    from obs order by backlog, sampled_at desc
),
-- The negative cache that excludes the same securities, over the same window.
cache as (
  select p.backlog,
         regr_slope(u.value, extract(epoch from u.sampled_at) / 86400.0) as cache_per_day
    from market.backlog_negative_cache p
    join market.universe_sample u
      on u.metric = 'missing.security.' || p.missing_column
     and u.sampled_at > now() - interval '7 days'
   where p.missing_column is not null
   group by p.backlog
)
select
  l.backlog,
  l.depth,
  l.sampled_at                                     as measured_at,
  f.samples,
  round(f.per_day::numeric, 1)                     as per_day,
  round(coalesce(c.cache_per_day, 0)::numeric, 1)  as cache_per_day,
  -- DAYS TO EMPTY, and NULL rather than a negative number when it is not draining. A backlog that
  -- grows has no ETA; reporting one as a negative would put a number on a chart that means the
  -- opposite of what it reads.
  case when f.per_day < -0.01 and l.depth > 0
       then round((l.depth / -f.per_day)::numeric, 1) end as days_to_empty,
  case
    -- FEWER THAN SIX SAMPLES IS NOT A TREND. Coverage samples twice a day, so a fresh deployment
    -- would otherwise report confident nonsense for its first three days.
    when f.samples < 6                              then 'insufficient_history'
    when l.depth = 0                                then 'empty'
    -- THE ONE THAT MATTERS. Draining while the negative cache grows at a comparable rate is the
    -- 2026-08-13 signature: ~8,300 securities marked unanswerable, every count reading as progress.
    when f.per_day < -0.01
     and coalesce(c.cache_per_day, 0) > 0.5 * -f.per_day  then 'draining_by_marking'
    when f.per_day < -0.01                          then 'draining'
    when f.per_day >  0.01                          then 'growing'
    else 'FLAT'
  end                                              as state
from latest l
join fit f using (backlog)
left join cache c using (backlog)
order by
  case when f.samples < 6 then 3
       when f.per_day < -0.01 and coalesce(c.cache_per_day,0) > 0.5 * -f.per_day then 0
       when l.depth > 0 and f.per_day >= -0.01 then 1
       else 2 end,
  l.depth desc;

comment on view market.backlog_drain is
  'Depth, rate of change and days-to-empty per backlog, from backlog_sample over 7 days. FLAT with a non-zero depth is the stall signature this pipeline has hit seven times; draining_by_marking is the 2026-08-13 signature, where a backlog empties by negative-caching rather than by working.';

grant select on market.backlog_drain to service_role, metrics_ro, anon;

-- ── AND A BACKLOG THAT LISTS WORK NOBODY CAN DO ───────────────────────────────────────────────
--
-- `pending_local_symbol` returned 281 securities while `security-local-symbols` reported
-- `no addressable securities pending` on every run. Both were right: the resource filters by
-- `hasLocalExchange(country)` in TypeScript, and MEASURED 2026-08-28 all 281 are in countries with
-- no `market.exchange` row at all — Cayman 118, Bermuda 56, Luxembourg 20, Russia 16, Iceland 15,
-- Marshall Islands 10. Offshore domiciles and unlisted venues, none of which has a local line to
-- resolve.
--
-- The rule lived in the RESOURCE and not in the VIEW, so the backlog metric read 281 for ever
-- while the resource correctly did nothing — the same fact in two places, which this schema
-- already records as certain to drift (the venue map reached 54 rows against 38 that way). The
-- view now owns it and the resource's filter becomes a redundant safety net rather than the rule.
create or replace view market.pending_local_symbol as
select
  s.security_id,
  s.country_iso2,
  isin.value as isin,
  coalesce(max(h.weight), 0) as best_weight
from market.security s
join market.security_identifier isin
  on isin.security_id = s.security_id and isin.kind_code = 'isin'
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.fund_holding_current h
  on h.security_id = s.security_id
where ps.security_id is null
  and s.security_type_code = 'equity'
  and s.country_iso2 is not null
  and s.country_iso2 <> 'US'
  -- ONLY WHERE THERE IS A VENUE TO RESOLVE AGAINST.
  and exists (select 1 from market.exchange e where e.country_iso2 = s.country_iso2)
  and (s.local_symbol_missing_at is null or s.local_symbol_missing_at < now() - interval '30 days')
group by s.security_id, s.country_iso2, isin.value
order by best_weight desc;

grant select on market.pending_local_symbol to service_role;

notify pgrst, 'reload schema';
