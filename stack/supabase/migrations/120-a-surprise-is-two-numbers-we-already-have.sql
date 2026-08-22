-- DID THE COMPANY BEAT ITS ESTIMATE? — from two numbers already in this schema.
--
-- The plan called for `equity/fundamental/historical_eps` (alpha_vantage) to get actual-versus-
-- estimate and the surprise. That endpoint could never have served this: alpha_vantage allows
-- **25 calls a day** and covers US listings only, which is useless as a backlog — 12,350 equities
-- at 25 a day is a year and a half — and this repository already records that.
--
-- It is also unnecessary. Both halves are here:
--
--   * the ACTUAL — `security_metric.eps_diluted` at `period_type = 'quarter'`, 98,333 rows, from
--     SEC XBRL where the filer publishes it and yfinance otherwise;
--   * the ESTIMATE — `earnings_calendar.eps_consensus`, with the period it refers to.
--
-- So the surprise is a join, not a fetch. Seventh instance of "the answer is already in a response
-- you fetch", except this time the two responses were fetched by different resources months apart.
--
-- ── MATCHING A MONTH TO A PERIOD END ────────────────────────────────────────────────────────────
--
-- `earnings_calendar.period_ending` is a MONTH ('2026-06'); the metric's `as_of` is a date
-- (2026-06-30). They usually agree, but a 52/53-week fiscal calendar ends a quarter on the nearest
-- Saturday — AAPL's Q2 is 2026-03-28, not 2026-03-31 — and can fall either side of a month
-- boundary. So the match is the named month WIDENED BY A WEEK at each end, not string equality:
-- exact matching would silently drop every 52/53-week filer, which is most US retail and tech.

drop view if exists market.security_earnings_surprise;
create view market.security_earnings_surprise as
select
  e.security_id,
  e.symbol,
  e.report_date,
  e.period_ending,
  m.as_of                as period_end_date,
  e.eps_consensus        as expected,
  m.value                as actual,
  m.value - e.eps_consensus as surprise,
  -- A PERCENTAGE NEEDS A NON-ZERO BASE, and `abs` because a company expected to lose 0.10 and
  -- losing 0.05 has BEATEN the estimate: dividing by a negative would report that as -50%.
  case when e.eps_consensus <> 0
       then round((m.value - e.eps_consensus) / abs(e.eps_consensus) * 100, 2) end as surprise_pct,
  (m.value >= e.eps_consensus) as beat
from market.earnings_calendar e
join market.security_metric m
  on m.security_id = e.security_id
 and m.metric_code = 'eps_diluted'
 and m.period_type = 'quarter'
 -- The named month, widened by a week at each end for 52/53-week fiscal calendars.
 and m.as_of >= (to_date(e.period_ending, 'YYYY-MM') - 7)
 and m.as_of <  (to_date(e.period_ending, 'YYYY-MM') + interval '1 month' + interval '7 days')
where e.security_id is not null
  and e.eps_consensus is not null
  -- Only REPORTED quarters. A consensus for a quarter that has not happened has nothing to be
  -- compared against, and pairing it with a stale actual would invent a surprise.
  and e.report_date <= current_date;

comment on view market.security_earnings_surprise is
  'Actual diluted EPS against the consensus that preceded it. Derived from `security_metric` and `earnings_calendar` rather than fetched: `equity/fundamental/historical_eps` (alpha_vantage) allows 25 calls a day and covers US listings only, which cannot serve 12,350 equities. The period match widens the named month by a week each side because a 52/53-week fiscal calendar ends a quarter on the nearest Saturday.';

grant select on market.security_earnings_surprise to anon, authenticated, service_role;

notify pgrst, 'reload schema';
