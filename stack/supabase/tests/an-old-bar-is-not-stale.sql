-- AN OLD WEEKLY BAR IS HISTORY. AN OLD DAILY BAR IS STALE. `price_series` MUST TELL THEM APART.
--
-- The chart reads `market.price_series`, one arm per grain: the DAILY arm is a serving window, and
-- the WEEKLY arm is the long history, derived from the same `price_bar` rows one point per ISO
-- week. A reader picks a resolution with `grain`.
--
-- This file once also guarded the `security-prices` prune (`delete ... where grain = 'daily' and
-- date < <400 days ago>`) and the `pending_price_history` backlog, both of which kept a twenty-year
-- weekly series in `security_price` beside a rolling daily window. The price family moved to
-- Dagster (D2, 2026-09-12), its edge handlers were deleted (Phase 3, stage 1c) and nothing writes
-- `security_price` any more, so those assertions went with them. The serving contract is what is
-- left, and it is what the app depends on.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZQ','Priceland','ZQ',false)
  on conflict (iso2) do nothing;

insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009401', 'T94 Long History', 'equity', 'ZQ')
on conflict (security_id) do nothing;
-- A TICKER, because `price_series` is read by symbol and resolves it through `symbol_security`.
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T94A', '00000000-0000-0000-0000-000000009401', 'yfinance')
on conflict (kind_code, value) do nothing;

-- A MATERIALIZED VIEW MAKES THIS A SNAPSHOT TEST. `price_series` joins `market.symbol_security`,
-- which is materialised (migration 102) — so rows inserted in this transaction are invisible to it
-- until it is rebuilt. NON-concurrently, deliberately: `refresh ... concurrently` cannot run inside
-- a transaction block, and a test that cannot roll back is not a test.
refresh materialized view market.symbol_security;

-- THREE DISTINCT WEEKS, NOT THREE ROWS. A derived weekly series takes the last close of each week,
-- so three bars inside one week would render as ONE point and the assertion would fail for a
-- reason that has nothing to do with the view.
insert into market.price_bar (security_id, trade_date, close, source_code) values
  ('00000000-0000-0000-0000-000000009401', date '2006-03-03', 10, 'yfinance'),
  ('00000000-0000-0000-0000-000000009401', date '2015-07-10', 20, 'yfinance'),
  -- RELATIVE, NOT FIXED. This is the one bar inside the daily serving window, so a literal date
  -- turns the assertion below into a time bomb: `2026-06-05` leaves the window in mid-2027 and the
  -- test then fails for a reason that has nothing to do with what it tests.
  ('00000000-0000-0000-0000-000000009401', current_date - 30, 30, 'yfinance')
on conflict (security_id, trade_date) do update set close = excluded.close;

do $$
declare n int;
begin
  select count(*) into n from market.price_series where symbol = 'T94A' and grain = 'weekly';
  if n <> 3 then
    raise exception 'price_series returns % weekly bars for T94A, not 3 — three distinct ISO weeks '
                    'must render three derived points', n;
  end if;
  -- THE DAILY ARM IS A WINDOW AND THE WEEKLY ARM IS HISTORY — which is exactly what this file's
  -- closing line has always claimed, and what the assertion here briefly contradicted. When the
  -- D2 cutover moved this arm from `security_price` (which the old resource only ever filled with
  -- a rolling ~400 days) onto `price_bar` (everything back to 1980), AAPL went 275 rows -> 11,528
  -- and the app began making twelve round trips to draw at most 365 days. The assertion was
  -- updated to expect all three, which recorded the regression as the contract.
  select count(*) into n from market.price_series where symbol = 'T94A' and grain = 'daily';
  if n <> 1 then
    raise exception 'price_series returns % daily bars for T94A, not 1 — only the bar inside the '
                    'serving window belongs to the daily arm; the two historical ones are what '
                    'the weekly arm is for', n;
  end if;
end $$;

rollback;

\echo 'ok: the daily arm is a window and the weekly arm keeps the whole history'
