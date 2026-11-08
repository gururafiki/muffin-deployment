-- AN ANALYST ACTION IS SERVED ONCE, BY ITS BEST SOURCE. Migrations 20261108210000 and
-- 20261108220000.
--
-- `security_price_target` holds finviz's frozen actions and, from the Dagster company lane,
-- Yahoo's. The key carries the provider and the action's timestamp, so both can be stored, and
-- `security_analyst_action` serves a company from its best source alone:
--   * a company Yahoo covers shows only Yahoo's rows, including finviz rows on days Yahoo states
--     nothing for that firm: the two providers spell firms differently ("BofA Securities" against
--     "B of A Securities"), so matching single actions across them showed one action twice;
--   * a company only finviz covers still shows finviz's rows (the backup);
--   * Yahoo's two actions by one firm on one day, seconds apart, both show (AAPL has two such
--     pairs in 971), which a key or a view on the date alone would collapse.
-- The fixture makes the plausible wrong rules disagree: matching by firm and day leaves finviz's
-- other-firm and other-day rows on a covered company, distinct-on-the-day drops one of the pair,
-- and a reversed priority serves finviz over Yahoo.

\set ON_ERROR_STOP on
begin;

insert into market.currency (code, name) values ('USD', 'US Dollar') on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009201', 'T201 analyst actions', 'equity', 'ZM'),
  ('00000000-0000-0000-0000-000000009202', 'T202 finviz only',     'equity', 'ZM')
on conflict (security_id) do nothing;

insert into market.security_price_target
  (security_id, source_code, published_at, published_date, analyst_company, target_from, target_to,
   currency_code, status, rating_change)
values
  -- 2026-10-01: both sources, same firm, the firm's case differs. Yahoo must win.
  ('00000000-0000-0000-0000-000000009201', 'finviz', '2026-10-01 00:00:00+00', '2026-10-01',
   'morgan stanley', 300, 320, 'USD', 'Reiterated', 'Overweight'),
  ('00000000-0000-0000-0000-000000009201', 'yfinance', '2026-10-01 14:02:11+00', '2026-10-01',
   'Morgan Stanley', 310, 330, 'USD', 'Maintains', 'Overweight'),
  -- 2026-10-02: finviz only. Must show.
  ('00000000-0000-0000-0000-000000009201', 'finviz', '2026-10-02 00:00:00+00', '2026-10-02',
   'Needham', null, 280, 'USD', 'Initiated', 'Buy'),
  -- 2026-10-03: Yahoo, one firm twice in a day, seconds apart. Both must show.
  ('00000000-0000-0000-0000-000000009201', 'yfinance', '2026-10-03 09:00:00+00', '2026-10-03',
   'Wedbush', 350, 360, 'USD', 'Maintains', 'Outperform'),
  ('00000000-0000-0000-0000-000000009201', 'yfinance', '2026-10-03 09:00:41+00', '2026-10-03',
   'Wedbush', 360, 365, 'USD', 'Maintains', 'Outperform'),
  -- 2026-10-03: finviz, a different firm on Yahoo's day. Hidden: Yahoo covers this company.
  ('00000000-0000-0000-0000-000000009201', 'finviz', '2026-10-03 00:00:00+00', '2026-10-03',
   'Rosenblatt', 340, 345, 'USD', 'Reiterated', 'Buy'),
  -- A company only finviz covers. Both rows must show.
  ('00000000-0000-0000-0000-000000009202', 'finviz', '2026-09-01 00:00:00+00', '2026-09-01',
   'Needham', null, 50, 'USD', 'Initiated', 'Buy'),
  ('00000000-0000-0000-0000-000000009202', 'finviz', '2026-09-15 00:00:00+00', '2026-09-15',
   'Wedbush', 50, 55, 'USD', 'Reiterated', 'Outperform');

do $$
declare
  covered constant uuid := '00000000-0000-0000-0000-000000009201';
  only_finviz constant uuid := '00000000-0000-0000-0000-000000009202';
  n int;
  src text;
begin
  select count(*) into n from market.security_analyst_action where security_id = covered;
  if n <> 3 then
    raise exception 'a company Yahoo covers must show Yahoo''s 3 actions only, got %', n;
  end if;

  select string_agg(distinct source_code, ',') into src from market.security_analyst_action
   where security_id = covered;
  if src is distinct from 'yfinance' then
    raise exception 'a company Yahoo covers must show no finviz row (another firm, another day, '
                    'another spelling would show one action twice); got sources %', src;
  end if;

  select count(*) into n from market.security_analyst_action
   where security_id = covered and analyst_company = 'Wedbush';
  if n <> 2 then
    raise exception 'one firm acting twice in a day, seconds apart, is two actions; got %', n;
  end if;

  select count(*) into n from market.security_analyst_action
   where security_id = only_finviz and source_code = 'finviz';
  if n <> 2 then
    raise exception 'a company only finviz covers must still show finviz''s rows; got %', n;
  end if;

  -- THE FLOOR: every stored row is still there. The view hides; it never deletes.
  select count(*) into n from market.security_price_target where security_id in (covered, only_finviz);
  if n <> 8 then
    raise exception 'expected 8 stored actions, got %', n;
  end if;

  raise notice 'ok  a company is served from its best source alone; finviz shows only where Yahoo is silent';
end $$;

rollback;
