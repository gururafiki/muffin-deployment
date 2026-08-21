-- A DATE ALONE DOES NOT SAY WHETHER IT IS A FORECAST OR A FACT.
--
-- `security_next_earnings` serves ONE row per security, and the choice it makes is the whole point:
-- the NEXT scheduled report where there is one, the most recent past one otherwise, and `upcoming`
-- saying which. A page rendering "reports 26 Aug" for a date that has passed is worse than showing
-- nothing — the reader cannot tell from the date that the number beside it is now history.
--
-- The fixture gives one security BOTH a past and a future date, because a security with only one
-- cannot tell "prefer the future" from "prefer the nearest" from "prefer the newest row".

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('nasdaq','Nasdaq',60) on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Earningsland','ZW',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000011501','T115 Both','equity','ZW'),
  ('00000000-0000-0000-0000-000000011502','T115 Past only','equity','ZW')
on conflict (security_id) do nothing;

insert into market.earnings_calendar
  (symbol, report_date, security_id, eps_consensus, reporting_time, source_code) values
  -- A has a past report AND a future one. The future one must win, and the PAST one must not be
  -- chosen merely because it is nearer to today.
  ('T115A', current_date - 2,  '00000000-0000-0000-0000-000000011501', 1.00, 'after-hours', 'nasdaq'),
  ('T115A', current_date + 30, '00000000-0000-0000-0000-000000011501', 2.00, 'before-market','nasdaq'),
  -- B has only past reports; the MOST RECENT must be chosen, not the oldest.
  ('T115B', current_date - 200,'00000000-0000-0000-0000-000000011502', 3.00, 'after-hours', 'nasdaq'),
  ('T115B', current_date - 10, '00000000-0000-0000-0000-000000011502', 4.00, 'after-hours', 'nasdaq'),
  -- An untracked company: the feed covers far more listings than this universe holds.
  ('T115Z', current_date + 3,  null, 9.00, 'after-hours', 'nasdaq')
on conflict (symbol, report_date) do nothing;

do $$
declare d date; up boolean; v numeric; n integer;
begin
  -- 1. THE FUTURE REPORT WINS, even though the past one is nearer to today. A rule written as
  --    "closest date" would pick the one two days ago.
  select report_date, upcoming, eps_consensus into d, up, v
    from market.security_next_earnings where symbol = 'T115A';
  if d is distinct from current_date + 30 then
    raise exception 'the next report is % , expected %  — a past date two days ago is NEARER, and choosing it would say "reports" about something already reported', d, current_date + 30;
  end if;
  if up is not true then raise exception 'a future report is not flagged upcoming'; end if;
  if v is distinct from 2.00 then raise exception 'the consensus came from the wrong row: %', v; end if;

  -- 2. WITH NOTHING SCHEDULED, THE MOST RECENT PAST REPORT — flagged as past.
  select report_date, upcoming into d, up
    from market.security_next_earnings where symbol = 'T115B';
  if d is distinct from current_date - 10 then
    raise exception 'the fallback chose % , expected the most recent past report %', d, current_date - 10;
  end if;
  if up is not false then
    raise exception 'a past report is flagged upcoming — the page would say "reports" about history';
  end if;

  -- 3. ONE ROW PER SECURITY. Two scheduled dates must not render as two answers.
  select count(*) into n from market.security_next_earnings
   where security_id = '00000000-0000-0000-0000-000000011501';
  if n <> 1 then raise exception 'a security with two calendar rows serves % answers', n; end if;

  -- 4. AN UNTRACKED COMPANY IS STORED BUT NOT SERVED. Keeping it stops the resource re-fetching the
  --    same unresolvable rows for ever; serving it would put a company on a page that does not
  --    exist in this universe.
  select count(*) into n from market.earnings_calendar where symbol = 'T115Z';
  if n <> 1 then raise exception 'an untracked company was discarded — it will be re-fetched for ever'; end if;
  select count(*) into n from market.security_next_earnings where symbol = 'T115Z';
  if n <> 0 then raise exception 'an untracked company is served'; end if;
end $$;

rollback;

\echo 'ok: an earnings date answers which question'
