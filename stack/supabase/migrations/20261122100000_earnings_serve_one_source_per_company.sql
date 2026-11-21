-- EARNINGS SERVE ONE SOURCE PER COMPANY, AND THE STOCK PAGE CAN READ THE HISTORY (Phase 6b step 2,
-- umbrella docs/specs/2026-11-21-macro-and-events.md).
--
-- Phase 6b adds Yahoo beside nasdaq for earnings (decided 2026-11-21). The company lane already
-- stores Yahoo's `calendarEvents` and `earningsHistory` for ~13,850 securities, and nothing reads
-- them. This migration is the ADDITIVE half. The keys gain the provider in the cutover migration
-- that retires the edge's two earnings resources, because their upserts name `(symbol,
-- report_date)` and `(security_id, period_ending)` as conflict targets and would fail on every run
-- until then.
--
-- WHY ONE SOURCE PER COMPANY. Measured 2026-11-21 on the 1,097 quarters both nasdaq and Yahoo hold
-- for the same company: actual EPS agrees on 65%, estimates on 50%. The rest are exact factors of
-- 10 (an ADR ratio, 0.885 against 8.85) and different adjusted bases (1.14 against 0.67). A series
-- mixing them would chart two EPS bases as one. This is the analyst-actions rule
-- (muffin-deployment#505).
--
-- WHY THE CHOICE IS BY DATA, NOT BY `source_priority()`. `yfinance` carries priority 100 against
-- nasdaq's 60, and that order decides statement precedence everywhere; re-ranking it for earnings
-- would reorder those too. So:
--   * history: each company's series comes from the source holding the MOST quarters for it,
--     among the sources that are CURRENT (their newest quarter within 100 days of the newest any
--     source holds); a tie goes to priority. nasdaq's history runs to 2012 for US companies, while
--     Yahoo adds four quarters per visit. Measured on production before shipping: by count alone,
--     AAPL would have been served alpha-vantage's 81 quarters, which END in 2016, over nasdaq's 41
--     current ones;
--   * next date: an UPCOMING row wins over a past one, and among upcoming rows the most recently
--     fetched wins. nasdaq re-reads its forward window daily and Yahoo visits weekly, so nasdaq
--     wins where both hold a date. Yahoo's "next" date was already past at fetch time for 61% of
--     the companies measured, so a past Yahoo row can never displace an upcoming one.
--
-- WHAT.
--   1. `earnings_calendar` gains Yahoo's `calendarEvents` fields: the date range end, whether the
--      date is an estimate, the EPS range, and the revenue consensus.
--   2. `yahoo-rss` joins `data_source` for the news lane.
--   3. `security_next_earnings` makes the choice above and appends its new columns. An
--      unchanged prefix lets `create or replace` keep the view's grants.
--   4. `security_earnings_history`: one row per quarter from the chosen source. The surprise is
--      COMPUTED from actual and estimate, so two sources' stored surprise columns (nasdaq's
--      percent, a fraction elsewhere) can never disagree with the figures beside them; it is
--      divided by the estimate's MAGNITUDE, so a loss smaller than expected reads as a beat.
--   5. `ingest_rw` may execute `prune_news`, for the Dagster news lane.

alter table market.earnings_calendar
  add column if not exists report_date_end date,
  add column if not exists is_date_estimate boolean,
  add column if not exists eps_low numeric,
  add column if not exists eps_high numeric,
  add column if not exists revenue_consensus numeric;

insert into market.data_source (code, name, priority)
values ('yahoo-rss', 'Yahoo Finance RSS headlines', 50)
on conflict (code) do nothing;

create or replace view market.security_next_earnings as
select distinct on (e.security_id)
       e.security_id,
       e.symbol,
       e.report_date,
       e.eps_consensus,
       e.eps_previous,
       e.num_estimates,
       e.reporting_time,
       e.period_ending,
       e.report_date >= current_date as upcoming,
       e.as_of,
       e.report_date_end,
       e.is_date_estimate,
       e.eps_low,
       e.eps_high,
       e.revenue_consensus,
       e.source_code
  from market.earnings_calendar e
 where e.security_id is not null
 -- THE FIRST KEY ALSO PUTS UPCOMING ROWS FIRST: a past row's key is NULL and sorts last, and `as_of`
 -- is NOT NULL, so an upcoming row always has one. A separate `upcoming desc` key would be the same
 -- rule spelled twice, and a mutation deleting it changed nothing.
 order by e.security_id,
          case when e.report_date >= current_date then e.as_of end desc nulls last,
          abs(e.report_date - current_date),
          e.as_of desc;

drop view if exists market.security_earnings_history;
create view market.security_earnings_history as
with per_source as (
  select security_id, source_code, count(*) as quarters, max(period_ending) as newest,
         max(max(period_ending)) over (partition by security_id) as newest_any
    from market.security_eps_history
   group by security_id, source_code
), chosen as (
  select distinct on (s.security_id) s.security_id, s.source_code
    from per_source s
    join market.data_source ds on ds.code = s.source_code
   order by s.security_id, s.newest >= s.newest_any - 100 desc, s.quarters desc, ds.priority desc,
            s.source_code
)
select h.security_id,
       h.period_ending,
       h.reported_date,
       h.eps_actual as actual,
       h.eps_estimated as estimate,
       h.eps_actual - h.eps_estimated as surprise,
       case when h.eps_estimated <> 0
            then round((h.eps_actual - h.eps_estimated) / abs(h.eps_estimated) * 100, 2)
       end as surprise_pct,
       h.eps_actual >= h.eps_estimated as beat,
       h.source_code,
       h.as_of
  from market.security_eps_history h
  join chosen c on c.security_id = h.security_id and c.source_code = h.source_code;

grant select on market.security_earnings_history to anon, authenticated, service_role;

-- 5. THE NEWS LANE PRUNES WITH THE EDGE'S OWN RULE. `ingest_rw` holds DELETE on `news_article` but
--    not EXECUTE on the function that states the retention window, which the baseline revoked from
--    PUBLIC. Granting it keeps the 90 days in one place rather than copying the delete into Python.
--    The revoke comes first because a grant can only ADD: re-applied, it removes any role that
--    gained the function since, so the worker stays the only caller.
revoke execute on function market.prune_news(integer) from public, anon, authenticated;
grant execute on function market.prune_news(integer) to ingest_rw;
