-- AN NSE WALK THAT LISTS NOTHING MUST LEAVE THE QUEUE, AND ONLY THAT WALK.
--
-- WHY THIS EXISTS AS A TEST. `in-filings` stamped a walk by updating a `security_filer` row that
-- exists only when NSE listed something. For a company NSE listed nothing for, the update matched
-- no row and raised nothing, so `pending_in_history` returned the same six companies at its head
-- every 15 minutes for two weeks (2026-10-06..20), with 289 behind them never reached. The walk is
-- now recorded on the security (`nse_history_walked_at`) while there is no filer row.
--
-- THE FIXTURE MAKES THE CANDIDATE RULES DISAGREE.
--
--   * the old view (no security cursor)                  queues row 1, walked an hour ago
--   * "either cursor counts" (greatest / coalesce)       holds row 5 out, though its NSE id resolved
--                                                        after the walk and has never been asked
--   * the security cursor with no season                 holds row 3 out for ever
--   * the security cursor alone, ignoring the filer row  queues row 4, walked an hour ago by its id

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('IN','India','IN',true)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix) values ('IN','IN','.NS')
on conflict (exch_code) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, nse_history_walked_at) values
  -- 1. No filer row, walked an hour ago under its listing symbol, NSE listed nothing. NOT queued.
  ('00000000-0000-0000-0000-000000201a01','T201 Trust Walked','equity','IN', now() - interval '1 hour'),
  -- 2. No filer row, never walked. Queued.
  ('00000000-0000-0000-0000-000000201a02','T201 Never Walked','equity','IN', null),
  -- 3. No filer row, walked 100 days ago: the season is over. Queued.
  ('00000000-0000-0000-0000-000000201a03','T201 Last Season','equity','IN', now() - interval '100 days'),
  -- 4. A filer row walked an hour ago. NOT queued, whatever the security's own cursor says.
  ('00000000-0000-0000-0000-000000201a04','T201 Filer Walked','equity','IN', null),
  -- 5. Walked an hour ago under the listing symbol, and the NSE id resolved since. The walk under
  --    the right name has never happened. Queued.
  ('00000000-0000-0000-0000-000000201a05','T201 Id Resolved','equity','IN', now() - interval '1 hour'),
  -- 6. A filer row whose own walk is 100 days old, beside a fresh security cursor. Queued.
  ('00000000-0000-0000-0000-000000201a06','T201 Filer Stale','equity','IN', now() - interval '1 hour')
on conflict (security_id) do nothing;

insert into market.listing (security_id, exch_code, symbol, is_primary) values
  ('00000000-0000-0000-0000-000000201a01','IN','T201TRUST', true),
  ('00000000-0000-0000-0000-000000201a02','IN','T201NEVER', true),
  ('00000000-0000-0000-0000-000000201a03','IN','T201SEASON', true),
  ('00000000-0000-0000-0000-000000201a04','IN','T201FILER', true),
  ('00000000-0000-0000-0000-000000201a05','IN','T201ABBR', true),
  ('00000000-0000-0000-0000-000000201a06','IN','T201STALE', true)
on conflict (security_id, exch_code) do nothing;

insert into market.security_filer (security_id, source_code, filer_id, history_walked_at) values
  ('00000000-0000-0000-0000-000000201a04','nse','T201FILER', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-000000201a05','nse','T201RESOLVED', null),
  ('00000000-0000-0000-0000-000000201a06','nse','T201STALE', now() - interval '100 days')
on conflict do nothing;

do $$
declare v_got text; v_want text := 'T201 Filer Stale, T201 Id Resolved, T201 Last Season, T201 Never Walked';
begin
  select string_agg(s.name, ', ' order by s.name) into v_got
    from market.pending_in_history p join market.security s using (security_id)
   where p.security_id::text like '00000000-0000-0000-0000-000000201a0%';

  if v_got is distinct from v_want then
    raise exception 'pending_in_history queues [%], expected [%]. A company NSE listed nothing for '
                    'must leave the queue for its season (T201 Trust Walked), a resolved NSE id must '
                    'earn a walk under that id (T201 Id Resolved), a season must end (T201 Last '
                    'Season), and a filer row''s own walk decides once the row exists (T201 Filer '
                    'Walked)', coalesce(v_got, 'nothing'), v_want;
  end if;

  -- The resolved id is the symbol asked, not the listing symbol the first walk used.
  select symbol into v_got from market.pending_in_history
   where security_id = '00000000-0000-0000-0000-000000201a05';
  if v_got is distinct from 'T201RESOLVED' then
    raise exception 'the resolved company would be asked as %, not by its NSE id T201RESOLVED',
                    coalesce(v_got, 'null');
  end if;

  raise notice 'ok  an NSE walk that lists nothing leaves the queue for its season, and only that walk';
end $$;

rollback;
