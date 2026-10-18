-- ASKING SEC ABOUT A COMPANY IT DOES NOT LIST IS NOT FREE — IT COSTS THE REST OF THE QUEUE.
--
-- `pending_statements` had two halves. `missing` was "no statements at all" and was served by
-- yfinance, which needs no US listing. The other half, `no_currency` and since 2026-10-10 `no_sec`,
-- is "a CIK holder with no SEC row", served by SEC, which only knows US registrants.
--
-- The SEC half was scoped on having a CIK and a ticker. Both are satisfied by companies SEC has
-- never heard of: a CIK can be resolved for a foreign filer, and `security_identifier.ticker` is
-- OpenFIGI's US lookup, which returns a thin OTC foreign-ordinary line for most foreign companies.
--
-- Measured 2026-09-07: of 2,817 securities in that half, **2,317 had no US listing and ZERO of
-- those 2,317 had ever received a sec-sourced statement**. And the queue is weight-ordered, so
-- they sat at the head — across the same day `no_currency` fell 3,050 -> 2,817 while `missing`
-- went 2,922 -> **2,921**. Securities with no statements at all were starving behind securities
-- that can never be helped.
--
-- 2026-10-18: THE QUEUE IS SEC'S ALONE. Yahoo's statements are the Dagster company lane's, so the
-- yfinance half left the edge (it held 26 securities Yahoo answers nothing for). The listing and
-- CIK rules now apply to BOTH halves: a security with no statements is still asked, of SEC, when SEC
-- can answer for it (row 4), and is no longer queued when it cannot (rows 3 and 5).
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. Rows 1 and 2 differ only in the listing; rows 3,
-- 4 and 5 hold no statements and differ only in the listing and the CIK. The old view queued 3 and 5
-- (the yfinance half), a view that dropped the `missing` half entirely would lose 4, and a view that
-- applied the listing rule without the CIK rule would keep 5.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.currency (code) values ('USD') on conflict do nothing;
insert into market.data_source (code, name) values ('yfinance','yfinance') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZL','Listland','ZL',false)
  on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix) values
  ('US','US',''), ('ZL','ZL','.ZL') on conflict (exch_code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  -- 1. US-listed, holding only Yahoo's statements: SEC can plausibly answer, so it is asked.
  ('00000000-0000-0000-0000-000000019701','T197 Listed Inc',   'equity','ZL', 1970001),
  -- 2. NOT US-listed. Has a CIK and a ticker, and SEC has never served one of these.
  ('00000000-0000-0000-0000-000000019702','T197 Unlisted SA',  'equity','ZL', 1970002),
  -- 3. No statements at all AND no US listing. The yfinance half served this one; nothing on the
  --    edge does now, and SEC cannot be asked about it.
  ('00000000-0000-0000-0000-000000019703','T197 Nothing Yet',  'equity','ZL', 1970003),
  -- 4. No statements at all, a CIK and a US listing: SEC is asked, and this is the row that stops
  --    the change dropping the `missing` half rather than scoping it.
  ('00000000-0000-0000-0000-000000019704','T197 Nothing Listed','equity','ZL', 1970004),
  -- 5. No statements at all and a US listing, but NO CIK: SEC is addressable only by its own
  --    registrants, so the CIK rule applies to this half too.
  ('00000000-0000-0000-0000-000000019705','T197 Nothing No Cik','equity','ZL', null)
on conflict (security_id) do nothing;

-- 6. Row 4's shape, carrying a recent `statements_missing_at`. That mark was the yfinance half's
--    ("no provider had statements") and says nothing about SEC, so it no longer excludes anything
--    here. Verisure and Midea were in exactly this state on 2026-10-18.
insert into market.security (security_id, name, security_type_code, country_iso2, cik,
                             statements_missing_at) values
  ('00000000-0000-0000-0000-000000019706','T197 Marked By Yahoo','equity','ZL', 1970006, now())
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000019701','ticker','T197L'),
  ('00000000-0000-0000-0000-000000019702','ticker','T197UF'),
  ('00000000-0000-0000-0000-000000019703','ticker','T197N'),
  ('00000000-0000-0000-0000-000000019704','ticker','T197NL'),
  ('00000000-0000-0000-0000-000000019705','ticker','T197NC'),
  ('00000000-0000-0000-0000-000000019706','ticker','T197MY')
on conflict (kind_code, value) do nothing;

insert into market.listing (security_id, exch_code, symbol, is_primary) values
  ('00000000-0000-0000-0000-000000019701','US','T197L', true),
  -- Foreign venue only, for rows 2 and 3.
  ('00000000-0000-0000-0000-000000019702','ZL','T197U', true),
  ('00000000-0000-0000-0000-000000019703','ZL','T197N2', true),
  ('00000000-0000-0000-0000-000000019704','US','T197NL', true),
  ('00000000-0000-0000-0000-000000019705','US','T197NC', true),
  ('00000000-0000-0000-0000-000000019706','US','T197MY', true)
on conflict (security_id, exch_code) do nothing;

-- Yahoo's statements, which put rows 1 and 2 in the `no_sec` half. Rows 3 to 6 get none.
insert into market.security_statement
  (security_id, statement, period_ending, period_type, data, source_code, currency, as_of)
select sid, 'income', date '2025-12-31', 'annual', '{}'::jsonb, 'yfinance', null, now()
  from unnest(array['00000000-0000-0000-0000-000000019701',
                    '00000000-0000-0000-0000-000000019702']::uuid[]) sid
on conflict do nothing;

do $$
declare listed int; unlisted int; nothing_unlisted int; nothing_listed int; nothing_no_cik int;
        marked_by_yahoo int; drain_column text;
begin
  select count(*) into listed from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000019701' and want = 'no_sec';
  select count(*) into unlisted from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000019702';
  select count(*) into nothing_unlisted from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000019703';
  select count(*) into nothing_listed from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000019704' and want = 'missing';
  select count(*) into nothing_no_cik from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000019705';
  select count(*) into marked_by_yahoo from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000019706' and want = 'missing';
  select missing_column into drain_column from market.backlog_negative_cache
   where backlog = 'pending_statements';

  if listed <> 1 then
    raise exception 'a US-LISTED CIK holder holding only Yahoo''s statements is not queued for SEC '
                    '(% rows) — that is the population this queue exists to serve', listed;
  end if;

  if unlisted <> 0 then
    raise exception 'a security with NO US listing is still queued for SEC (% rows) — measured, '
                    '2,317 such securities had never once been served by SEC, and being '
                    'weight-ordered they held the head while the rest of the queue moved by ONE row '
                    'in a day', unlisted;
  end if;

  if nothing_unlisted <> 0 then
    raise exception 'a security with no statements and NO US listing is still queued (% rows) — '
                    'the yfinance half that served it left the edge on 2026-10-18 (Yahoo''s '
                    'statements are the Dagster company lane''s), and SEC cannot be asked about it',
                    nothing_unlisted;
  end if;

  if nothing_listed <> 1 then
    raise exception 'a CIK holder with a US listing and NO statements at all is not queued (% rows) '
                    '— the change dropped the `missing` half instead of asking SEC for it',
                    nothing_listed;
  end if;

  if nothing_no_cik <> 0 then
    raise exception 'a security with no statements, a US listing and NO CIK is queued (% rows) — '
                    'SEC answers only for its registrants, so it would be asked for ever',
                    nothing_no_cik;
  end if;

  if marked_by_yahoo <> 1 then
    raise exception 'a CIK holder with a US listing is excluded by statements_missing_at (% rows) — '
                    'that mark recorded the yfinance half''s answer, which says nothing about SEC, '
                    'and its only writer left the edge on 2026-10-18', marked_by_yahoo;
  end if;

  -- The drain signal compares the backlog's fall with the rise of the cache it marks. Paired with
  -- a column nothing writes, `backlog_drain` could never report `draining_by_marking`.
  if drain_column is distinct from 'statement_currency_missing_at' then
    raise exception 'backlog_negative_cache pairs pending_statements with % — the handler marks '
                    'statement_currency_missing_at, so the drain signal watches a column nothing '
                    'writes', coalesce(drain_column, '<no row>');
  end if;

  raise notice 'ok  SEC is asked only where it can answer, including for a security with none yet';
end $$;

rollback;
