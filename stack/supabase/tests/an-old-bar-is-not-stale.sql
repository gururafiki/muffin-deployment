-- AN OLD WEEKLY BAR IS HISTORY. AN OLD DAILY BAR IS STALE. THE PRUNE MUST TELL THEM APART.
--
-- WHY THIS IS A TEST. `security-prices` ends every run with
--
--   delete from security_price where security_id in (...) and date < <400 days ago>
--
-- which is exactly right for a rolling daily window and would destroy a twenty-year weekly
-- backfill the first time the resource touched a security. The failure is SILENT in every way that
-- matters: no error, no count, nothing in `refresh_log`, and the only symptom is a chart that
-- quietly shortens back to 400 days — which looks like the backfill never ran.
--
-- The schema is what makes the distinction expressible, so this file asserts the schema too: with
-- `grain` outside the primary key a weekly and a daily bar for one date cannot coexist, the second
-- silently overwrites the first, and the 20-year series ends where the daily window begins.

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
-- A TICKER, because `pending_price_history` INNER JOINs `security_symbol` and a security with no
-- symbol is absent from the backlog whatever the rest of the predicate says. Without this the
-- security never enters the view, so "excludes securities that already have history" and "excludes
-- everything" give the same answer and assertion 6 proves nothing.
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T94A', '00000000-0000-0000-0000-000000009401', 'yfinance')
on conflict (kind_code, value) do nothing;

-- A SECOND security with a symbol and NO weekly history: it must BE in the backlog. Without a
-- positive case, a backlog that returns nothing at all passes assertion 6 trivially.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009402', 'T94 Needs History', 'equity', 'ZQ')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T94B', '00000000-0000-0000-0000-000000009402', 'yfinance')
on conflict (kind_code, value) do nothing;

-- A twenty-year weekly series and a recent daily one. The overlapping date is deliberate: both
-- grains legitimately carry 2026-06-05, and the schema has to hold both.
insert into market.security_price (security_id, date, close, grain) values
  ('00000000-0000-0000-0000-000000009401', date '2006-03-03', 10, 'weekly'),
  ('00000000-0000-0000-0000-000000009401', date '2015-07-10', 20, 'weekly'),
  ('00000000-0000-0000-0000-000000009401', date '2026-06-05', 30, 'weekly'),
  ('00000000-0000-0000-0000-000000009401', date '2026-06-05', 31, 'daily'),
  ('00000000-0000-0000-0000-000000009401', date '2024-01-04', 15, 'daily')
on conflict (security_id, grain, date) do nothing;

-- THE MARKER GOES WITH THE BARS, because that is what `security-price-history` does when it writes
-- them (migration 140). `pending_price_history` now keys on `security.price_history_from` rather
-- than scanning `security_price`: the scan measured 5.8s against ~8M weekly rows and grew with the
-- series, two seconds from the PostgREST role's statement timeout, and the coverage view paid the
-- same cost at 7.9s. A column read is 8ms.
--
-- It IS a denormalisation, and the risk it carries is divergence — which assertion 6b below is
-- what guards. An index was measured first and does not solve it: the plan is already an
-- index-only scan on the right index, and the cost is 14,489 buffer READS because that index is
-- 853MB and does not stay in cache on this node.
update market.security set price_history_from = date '2006-01-02'
 where security_id = '00000000-0000-0000-0000-000000009401';

-- A MATERIALIZED VIEW MAKES THIS A SNAPSHOT TEST. `price_series` joins `market.symbol_security`,
-- which is materialised (migration 102) — so rows inserted in this transaction are invisible to it
-- until it is rebuilt. NON-concurrently, deliberately: `refresh ... concurrently` cannot run inside
-- a transaction block, and a test that cannot roll back is not a test.
refresh materialized view market.symbol_security;

do $$
declare n integer; c numeric;
begin
  -- 1. BOTH GRAINS COEXIST ON ONE DATE. With `grain` outside the key the daily bar overwrites the
  --    weekly one and the long series develops a hole exactly where the two meet.
  select count(*) into n from market.security_price
   where security_id = '00000000-0000-0000-0000-000000009401' and date = date '2026-06-05';
  if n <> 2 then
    raise exception
      'one date holds % bars, not 2 — `grain` must be part of the primary key or a daily bar silently replaces the weekly one and the 20-year chart ends where the daily window starts', n;
  end if;

  -- 2. THE PRUNE THE RESOURCE RUNS. Written exactly as `security-prices` writes it, including the
  --    grain qualifier that is the whole point.
  delete from market.security_price
   where security_id = '00000000-0000-0000-0000-000000009401'
     and grain = 'daily'
     and date < (current_date - 400);

  -- 3. THE STALE DAILY BAR IS GONE. Without this the window is unbounded and the "~400 bars per
  --    security" sizing that justified storing daily bars at all stops being true.
  select count(*) into n from market.security_price
   where security_id = '00000000-0000-0000-0000-000000009401'
     and grain = 'daily' and date = date '2024-01-04';
  if n <> 0 then
    raise exception 'the prune left a daily bar older than the window — the daily series grows without bound';
  end if;

  -- 4. EVERY WEEKLY BAR SURVIVED, including the two decades older than the daily cutoff. This is
  --    the assertion the whole file exists for.
  select count(*) into n from market.security_price
   where security_id = '00000000-0000-0000-0000-000000009401' and grain = 'weekly';
  if n <> 3 then
    raise exception
      'the prune destroyed weekly history (% of 3 bars left) — an unqualified delete below the daily cutoff wipes the entire 20-year backfill, silently, the first time security-prices touches a security', n;
  end if;

  -- 5. AND THE OVERLAPPING WEEKLY BAR KEPT ITS OWN CLOSE, rather than being left holding the daily
  --    one. A silent overwrite here would make the long series disagree with the short one on the
  --    dates they share, which reads as a data-quality problem rather than a key problem.
  select close into c from market.security_price
   where security_id = '00000000-0000-0000-0000-000000009401'
     and grain = 'weekly' and date = date '2026-06-05';
  if c is distinct from 30 then
    raise exception 'the weekly bar on the overlapping date reads %, not its own close of 30', c;
  end if;

  -- 6. THE BACKLOG EXCLUDES A SECURITY THAT ALREADY HAS WEEKLY HISTORY, or the backfill re-fetches
  --    twenty years for the same securities on every run against a rate-limited provider.
  select count(*) into n from market.pending_price_history
   where security_id = '00000000-0000-0000-0000-000000009401';
  if n <> 0 then
    raise exception 'a security with weekly history is still queued for the backfill (% rows) — twenty years would be re-fetched for it on every run against a rate-limited provider', n;
  end if;

  -- 6b. THE MARKER AND THE BARS MUST AGREE. The backlog keys on `price_history_from`, so a
  --     security whose marker is missing while its bars exist would be re-fetched for twenty years
  --     — and one whose marker is set while its bars are gone would never be repaired. Neither
  --     shows up in any count, which is why it is asserted rather than trusted.
  select count(*) into n
    from market.security s
   where s.security_type_code = 'equity'
     and (s.price_history_from is not null) is distinct from
         (exists (select 1 from market.security_price p
                   where p.security_id = s.security_id and p.grain = 'weekly'));
  if n <> 0 then
    raise exception
      'price_history_from disagrees with security_price for % securities — the marker is a '
      'denormalisation of the bars, so a divergence means the backlog either re-fetches twenty '
      'years for a security that has them, or never repairs one that does not', n;
  end if;

  -- 7. AND THE ONE THAT NEEDS HISTORY IS QUEUED. Paired with 6 on purpose: a backlog that returns
  --    nothing at all satisfies 6 perfectly, so only the two together say the predicate works.
  select count(*) into n from market.pending_price_history
   where security_id = '00000000-0000-0000-0000-000000009402';
  if n <> 1 then
    raise exception 'a security with a symbol and no weekly history is NOT queued (% rows) — the backfill would never reach it', n;
  end if;

  -- 8. THE SERVING VIEW LETS A READER PICK A RESOLUTION. The two grains overlap by design, so a
  --    view that cannot be filtered hands the chart two bars for the same day — and a 20-year
  --    weekly series is 1,077 rows, above PGRST_DB_MAX_ROWS, so a reader that cannot narrow to one
  --    grain silently gets a truncated answer instead of an error.
  select count(*) into n from market.price_series
   where symbol = 'T94A' and grain = 'weekly';
  if n <> 3 then
    raise exception 'price_series returns % weekly bars for T94A, not 3 — the app cannot ask for one resolution', n;
  end if;
  select count(*) into n from market.price_series where symbol = 'T94A' and grain = 'daily';
  if n <> 1 then
    raise exception 'price_series returns % daily bars for T94A, not 1 (the stale one was pruned)', n;
  end if;
end $$;

rollback;

\echo 'ok: the prune bounds the daily window and leaves twenty years of weekly history alone'
