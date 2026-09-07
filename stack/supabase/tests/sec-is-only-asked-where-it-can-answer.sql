-- ASKING SEC ABOUT A COMPANY IT DOES NOT LIST IS NOT FREE — IT COSTS THE OTHER HALF OF THE QUEUE.
--
-- `pending_statements` has two halves. `missing` is "no statements at all" and is served by
-- yfinance, which needs no US listing. `no_currency` is "has statements, none carrying a currency"
-- — yfinance's income/balance/cash responses have no currency field — and is served by SEC, which
-- only knows US registrants.
--
-- The second half was scoped on having a CIK and a ticker. Both are satisfied by companies SEC has
-- never heard of: a CIK can be resolved for a foreign filer, and `security_identifier.ticker` is
-- OpenFIGI's US lookup, which returns a thin OTC foreign-ordinary line for most foreign companies.
--
-- Measured 2026-09-07: of 2,817 securities in that half, **2,317 had no US listing and ZERO of
-- those 2,317 had ever received a sec-sourced statement**. And the queue is weight-ordered, so
-- they sat at the head — across the same day `no_currency` fell 3,050 -> 2,817 while `missing`
-- went 2,922 -> **2,921**. Securities with no statements at all were starving behind securities
-- that can never be helped.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE. Every security below has a CIK, a ticker and
-- currency-less statements, so nothing separates them except the listing — and the `missing`
-- control has no US listing either, which is what stops the fix being applied to the wrong half.

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
  -- 1. US-listed: SEC can plausibly answer, so it must still be asked.
  ('00000000-0000-0000-0000-000000019701','T197 Listed Inc',   'equity','ZL', 1970001),
  -- 2. NOT US-listed. Has a CIK and a ticker, and SEC has never served one of these.
  ('00000000-0000-0000-0000-000000019702','T197 Unlisted SA',  'equity','ZL', 1970002),
  -- 3. THE CONTROL, and the row that stops the fix being applied to the wrong half: no statements
  --    at all AND no US listing. yfinance serves this one and needs no listing, so it must stay.
  ('00000000-0000-0000-0000-000000019703','T197 Nothing Yet',  'equity','ZL', 1970003)
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-000000019701','ticker','T197L'),
  ('00000000-0000-0000-0000-000000019702','ticker','T197UF'),
  ('00000000-0000-0000-0000-000000019703','ticker','T197N')
on conflict (kind_code, value) do nothing;

insert into market.listing (security_id, exch_code, symbol, is_primary) values
  ('00000000-0000-0000-0000-000000019701','US','T197L', true),
  -- Foreign venue only, for both of the others.
  ('00000000-0000-0000-0000-000000019702','ZL','T197U', true),
  ('00000000-0000-0000-0000-000000019703','ZL','T197N2', true)
on conflict (security_id, exch_code) do nothing;

-- Statements WITHOUT a currency, which is what puts 1 and 2 in the `no_currency` half. 3 gets none.
insert into market.security_statement
  (security_id, statement, period_ending, period_type, data, source_code, currency, as_of)
select sid, 'income', date '2025-12-31', 'annual', '{}'::jsonb, 'yfinance', null, now()
  from unnest(array['00000000-0000-0000-0000-000000019701',
                    '00000000-0000-0000-0000-000000019702']::uuid[]) sid
on conflict do nothing;

do $$
declare listed int; unlisted int; nothing_yet int;
begin
  select count(*) into listed from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000019701' and want = 'no_currency';
  select count(*) into unlisted from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000019702';
  select count(*) into nothing_yet from market.pending_statements
   where security_id = '00000000-0000-0000-0000-000000019703' and want = 'missing';

  if listed <> 1 then
    raise exception 'a US-LISTED security with currency-less statements is not queued for SEC '
                    '(% rows) — that is the population this half exists to serve', listed;
  end if;

  if unlisted <> 0 then
    raise exception 'a security with NO US listing is still queued for SEC (% rows) — measured, '
                    '2,317 such securities had never once been served by SEC, and being '
                    'weight-ordered they held the head while the `missing` half moved by ONE row '
                    'in a day', unlisted;
  end if;

  if nothing_yet <> 1 then
    raise exception 'a security with NO statements at all was dropped (% rows) — the listing rule '
                    'belongs to the SEC half only; the `missing` half is served by yfinance, which '
                    'needs no US listing, and applying it there would silently shrink the universe',
                    nothing_yet;
  end if;

  raise notice 'ok  SEC is asked only where it can answer, and the yfinance half is untouched';
end $$;

rollback;
