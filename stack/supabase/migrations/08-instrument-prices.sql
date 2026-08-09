-- Daily closes per instrument, for the stock page's chart.
--
-- The performance refresh ALREADY downloads full daily history for every symbol and
-- throws it away after computing returns, so storing a slice of it is nearly free —
-- and it keeps the read path the same as everything else: the app reads a table, no
-- API server in between.
--
-- BOUNDED TO ~400 CALENDAR DAYS ON PURPOSE. That is ~280 trading bars per symbol
-- (~13k rows across the universe), which draws 1M/3M/6M/YTD/1Y correctly. The 3Y and
-- 5Y *numbers* still exist in market.performance — only the CHART is bounded, and
-- the UI offers no range it cannot draw. Storing the full 5.2y at daily granularity
-- would be ~60k rows rewritten on every refresh for detail no phone-sized chart can
-- show.

create table if not exists market.prices (
  symbol text        not null references market.instruments (symbol) on delete cascade,
  date   date        not null,
  close  numeric     not null,
  primary key (symbol, date)
);

-- The chart reads one symbol ordered by date; the PK already serves that, but the
-- refresh also deletes by date across all symbols when trimming.
create index if not exists prices_date_idx on market.prices (date);

grant select on market.prices to anon, authenticated;
grant select, insert, update, delete on market.prices to service_role;

notify pgrst, 'reload schema';
