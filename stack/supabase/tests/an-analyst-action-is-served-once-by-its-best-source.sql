-- AN ANALYST ACTION IS SERVED ONCE, BY ITS BEST SOURCE. Migration 20261108210000.
--
-- `security_price_target` holds finviz's frozen actions and, from the Dagster company lane,
-- Yahoo's. The key carries the provider and the action's timestamp, so both can be stored, and
-- `security_analyst_action` serves each action once:
--   * a finviz row is hidden by a Yahoo row for the same firm, security and day, firm names
--     compared without case;
--   * a finviz row on a day Yahoo states nothing for that firm still shows (the backup);
--   * Yahoo's two actions by one firm on one day, seconds apart, both show (AAPL has two such
--     pairs in 971), which a key or a view on the date alone would collapse.
-- The fixture makes the plausible wrong rules disagree: distinct-on-the-day drops one of the pair,
-- a reversed priority serves finviz over Yahoo, and an exact firm match leaves the case-different
-- finviz row beside Yahoo's.

\set ON_ERROR_STOP on
begin;

insert into market.currency (code, name) values ('USD', 'US Dollar') on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000009201', 'T201 analyst actions', 'equity', 'ZM')
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
  -- 2026-10-03: finviz, a different firm on Yahoo's day. Must show: only the same firm hides it.
  ('00000000-0000-0000-0000-000000009201', 'finviz', '2026-10-03 00:00:00+00', '2026-10-03',
   'Rosenblatt', 340, 345, 'USD', 'Reiterated', 'Buy');

do $$
declare
  sid constant uuid := '00000000-0000-0000-0000-000000009201';
  n int;
  src text;
begin
  select count(*) into n from market.security_analyst_action where security_id = sid;
  if n <> 5 then
    raise exception 'expected 5 served actions (6 stored, finviz''s Morgan Stanley hidden), got %', n;
  end if;

  select string_agg(source_code, ',') into src from market.security_analyst_action
   where security_id = sid and published_date = '2026-10-01';
  if src is distinct from 'yfinance' then
    raise exception 'on 2026-10-01 the same firm from both sources must be served once, by Yahoo; got %', src;
  end if;

  select count(*) into n from market.security_analyst_action
   where security_id = sid and published_date = '2026-10-02' and source_code = 'finviz';
  if n <> 1 then
    raise exception 'a finviz action on a day Yahoo states nothing for that firm must still show; got %', n;
  end if;

  select count(*) into n from market.security_analyst_action
   where security_id = sid and analyst_company = 'Wedbush';
  if n <> 2 then
    raise exception 'one firm acting twice in a day, seconds apart, is two actions; got %', n;
  end if;

  select count(*) into n from market.security_analyst_action
   where security_id = sid and analyst_company = 'Rosenblatt';
  if n <> 1 then
    raise exception 'a different firm on Yahoo''s day must not be hidden; got %', n;
  end if;

  -- THE FLOOR: every stored row is still there. The view hides; it never deletes.
  select count(*) into n from market.security_price_target where security_id = sid;
  if n <> 6 then
    raise exception 'expected 6 stored actions, got %', n;
  end if;

  raise notice 'ok  an analyst action is served once, by its best source; a backup row shows where the best source is silent';
end $$;

rollback;
