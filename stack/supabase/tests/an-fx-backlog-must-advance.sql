-- A CURRENCY THAT HAS ITS HISTORY MUST LEAVE THE BACKLOG.
--
-- The first version of this probe read ROWS and let `PGRST_DB_MAX_ROWS` cap it at 1,000, so after
-- two currencies (~520 weekly rates each) it could no longer see past its own page: backfilled
-- currencies looked undone and were re-fetched for ever, three consecutive production runs
-- returning the identical `historyFor` while reporting no failures.
--
-- The trap the fixture has to make impossible is subtler than "does the view return rows": a
-- currency with today's SPOT rate has rows and is still not done, so a `where` over `fx_rate` would
-- wrongly satisfy it. That is why the test gives one currency spot only and another spot PLUS
-- history — the two must be told apart.

\set ON_ERROR_STOP on

begin;

insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100)
  on conflict (code) do nothing;
-- USD IS INSERTED BY THE FIXTURE, deliberately with NO rates. `market.currency` is populated by
-- the ingest at runtime, not by a migration, so on a fresh database the dollar does not exist and
-- the assertion below could never fire — it would report "USD is not queued" for the wrong reason
-- and certify the exclusion that is not there.
insert into market.currency (code, name) values
  ('USD','US Dollar'), ('T1A','Test spot only'), ('T1B','Test with history'), ('T1C','Test with nothing')
on conflict (code) do nothing;

-- SPOT ONLY: has rows, is not done.
insert into market.fx_rate (currency_code, as_of, usd_per_unit, source_code) values
  ('T1A', current_date,           0.5, 'yfinance'),
  ('T1A', current_date - 1,       0.5, 'yfinance'),
-- SPOT PLUS HISTORY: done.
  ('T1B', current_date,           0.5, 'yfinance'),
  ('T1B', current_date - 400,     0.5, 'yfinance')
on conflict (currency_code, as_of) do nothing;

do $$
declare n integer;
begin
  -- 1. A CURRENCY WITH ONLY RECENT ROWS IS STILL PENDING. Rows are not history.
  select count(*) into n from market.pending_fx_history where currency_code = 'T1A';
  if n <> 1 then
    raise exception 'a spot-only currency is not queued (% rows) — today''s rate is not ten years of them', n;
  end if;

  -- 2. ONE WITH AN OLD ROW HAS LEFT. This is the assertion the paged probe could not satisfy: it
  --    is what makes repeated runs terminate instead of re-fetching the same four currencies.
  select count(*) into n from market.pending_fx_history where currency_code = 'T1B';
  if n <> 0 then
    raise exception 'a backfilled currency is STILL queued — the backlog cannot drain and every run re-fetches it';
  end if;

  -- 3. ONE WITH NOTHING AT ALL IS QUEUED. An anti-join written as a join would drop it entirely,
  --    so the currency nobody has ever quoted would never be fetched.
  select count(*) into n from market.pending_fx_history where currency_code = 'T1C';
  if n <> 1 then
    raise exception 'a currency with no rates at all is not queued — an anti-join written as a join drops exactly this case';
  end if;

  -- 4. A CURRENCY THE PROVIDER HAS NO HISTORY FOR LEAVES THE BACKLOG. Yahoo carries a SINGLE bar
  --    for GELUSD=X, so the fetch succeeds, writes one recent row, and "has a rate older than 90
  --    days" stays false for ever — eight requests a day, no error, nothing wrong, pure waste.
  update market.currency set history_missing_at = now() where code = 'T1A';
  select count(*) into n from market.pending_fx_history where currency_code = 'T1A';
  if n <> 0 then
    raise exception 'a currency the provider has no history for is STILL queued — it will be re-asked for ever';
  end if;

  -- 5. BUT ONLY FOR 30 DAYS. A pair not quoted today may be quoted next quarter, and asking again
  --    monthly costs one request. `never` would be cheaper and wrong.
  update market.currency set history_missing_at = now() - interval '31 days' where code = 'T1A';
  select count(*) into n from market.pending_fx_history where currency_code = 'T1A';
  if n <> 1 then
    raise exception 'an expired negative cache did not re-queue the currency — the mark is permanent, not a cache';
  end if;

  -- 6. THE DOLLAR IS NEVER QUEUED. There is no USDUSD=X to fetch, and asking for one costs a
  --    request per run for ever.
  select count(*) into n from market.pending_fx_history where currency_code = 'USD';
  if n <> 0 then
    raise exception 'USD is queued for its own exchange rate';
  end if;
end $$;

rollback;

\echo 'ok: an fx backlog must advance'
