-- WHEN THIS COMPANY NEXT REPORTS — one call covers a hundred companies.
--
-- `equity/calendar/earnings?provider=nasdaq` takes a DATE RANGE, not a symbol: measured 2026-08-21
-- against a local openbb-api, a three-day window returned **116 companies** with `report_date`,
-- `eps_consensus`, `eps_previous`, `reporting_time` and `period_ending`. That makes it the cheapest
-- thing in this pipeline per fact delivered — everything else here is per-symbol or per-20-symbols.
--
-- A FIVE-DAY WINDOW TIMED OUT and a three-day one did not, so the window size is part of the
-- contract rather than a tuning knob. The resource walks the horizon in small chunks.
--
-- ── AND IT IS A ROLLING REFRESH, NOT A BACKLOG ──────────────────────────────────────────────────
--
-- Every other resource here drains a queue: ask once, mark done, never ask again. An earnings
-- calendar is the opposite — the horizon MOVES, dates get rescheduled and consensus estimates are
-- revised right up to the day. So there is no `pending_*` view and no negative cache: each run
-- re-reads the whole forward window, which is ~7 calls, and the newest answer wins. A backlog here
-- would freeze a date that later changed.
--
-- Rows are kept for 90 days after the fact so a page can say "reported on the 26th" as well as
-- "reports on the 26th", and then dropped: this is a calendar, not an archive of every earnings
-- date ever announced.

-- SEEDED HERE, BESIDE THE RESOURCE THAT WRITES IT. `source_code` is a foreign key, so a resource
-- writing an unseeded source dies on its FIRST REAL RUN with a constraint violation and takes the
-- whole batch with it — migration 88 did exactly that with 'sec', and the migration tests could not
-- see it because they apply to a database where no resource ever runs. `logic-check.ts` fails on any
-- `source_code: '<x>'` literal no migration seeds, and it caught this one.
--
-- Priority below the filing sources: an earnings CALENDAR is a schedule and a consensus, never the
-- reported figure. Nothing should ever prefer it over `sec` for a number.
insert into market.data_source (code, name, priority) values ('nasdaq', 'Nasdaq', 60)
on conflict (code) do nothing;

create table if not exists market.earnings_calendar (
  -- SYMBOL-KEYED, because the feed is. `security_id` is resolved where we track the company and
  -- left NULL where we do not — nasdaq covers far more US listings than this universe holds, and
  -- discarding the unresolved ones would mean re-fetching them for ever to learn the same nothing.
  symbol         text not null,
  report_date    date not null,
  security_id    uuid references market.security (security_id) on delete set null,
  name           text,
  eps_consensus  numeric,
  eps_previous   numeric,
  num_estimates  integer,
  period_ending  text,
  -- 'before-market', 'after-hours' — the difference between a number arriving before or after a
  -- trading day, which is the whole reason anyone checks.
  reporting_time text,
  source_code    text not null references market.data_source (code),
  as_of          timestamptz not null default now(),
  primary key (symbol, report_date)
);

comment on table market.earnings_calendar is
  'Upcoming and recent earnings dates from `equity/calendar/earnings`, which takes a DATE RANGE rather than a symbol — one call covers ~116 companies. A rolling refresh, not a backlog: the horizon moves and dates are rescheduled, so each run re-reads the whole forward window and the newest answer wins.';

create index if not exists earnings_calendar_security_idx
  on market.earnings_calendar (security_id, report_date);

grant select on market.earnings_calendar to anon, authenticated, service_role;
grant insert, update, delete on market.earnings_calendar to service_role;

alter table market.earnings_calendar enable row level security;
drop policy if exists earnings_calendar_read on market.earnings_calendar;
create policy earnings_calendar_read on market.earnings_calendar for select using (true);

-- The serving view: the NEXT report for each security we track, and the most recent past one.
-- `distinct on` picks per security, because a company appears once per scheduled date and a page
-- wants one answer.
drop view if exists market.security_next_earnings;
create view market.security_next_earnings as
select distinct on (e.security_id)
  e.security_id,
  e.symbol,
  e.report_date,
  e.eps_consensus,
  e.eps_previous,
  e.num_estimates,
  e.reporting_time,
  e.period_ending,
  -- Says which question this row answers. A page showing "reports 26 Aug" for a date that has
  -- passed is worse than showing nothing, and the reader cannot tell from the date alone whether
  -- the number is a forecast or a fact.
  (e.report_date >= current_date) as upcoming,
  e.as_of
from market.earnings_calendar e
where e.security_id is not null
  -- Prefer the next SCHEDULED report; fall back to the most recent past one when there is none.
order by e.security_id, (e.report_date >= current_date) desc, abs(e.report_date - current_date);

comment on view market.security_next_earnings is
  'One row per tracked security: its next scheduled earnings date, or the most recent past one when nothing is scheduled. `upcoming` says which — a page showing "reports 26 Aug" for a date that has passed is worse than showing nothing.';

grant select on market.security_next_earnings to anon, authenticated, service_role;

notify pgrst, 'reload schema';
