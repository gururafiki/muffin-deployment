-- Daily closes per instrument, for the stock page's chart.
--
-- The performance refresh ALREADY downloads full daily history for every symbol and
-- throws it away after computing returns, so storing a slice of it is nearly free —
-- and it keeps the read path the same as everything else: the app reads a table, no
-- API server in between.
--
-- BOUNDED AND DOWNSAMPLED ON PURPOSE: ~400 calendar days, daily for the most recent
-- 90 and weekly before that — ~107 bars per symbol, ~4.8k rows across the universe.
--
-- Measured 2026-08-09: storing all ~275 daily bars per symbol (12,625 rows) pushed
-- the edge worker past its 60 s limit while upserting, and production returned 502.
-- The openbb fetch is only ~9 s of that; the write is the cost. Downsampling keeps
-- 1M at full daily resolution and gives 1Y more points than a phone-width chart can
-- resolve.
--
-- The 3Y/5Y *numbers* still come from market.performance — only the CHART is
-- bounded, and the UI offers no range it cannot draw.

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
