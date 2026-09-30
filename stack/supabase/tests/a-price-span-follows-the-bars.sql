-- A security's price span is its first and last bar, and it follows the bars.
--
-- WHY THIS EXISTS. `market.security_price_span` replaces the two history markers the retired edge
-- resources wrote. The facets that read it decide whether a security "has its price history", so a
-- wrong span is a wrong coverage number with nothing to show for it. Migration 20261003110000
-- fills it through `market.derive_security_price_span()`.
--
-- Each fixture makes one rule the only thing deciding its answer:
--
--   T930 old history     bars in three years, inserted out of order: the span is the oldest and
--                        the newest, not the first and last written
--   T930 no bars         asked, holds nothing: a row with null dates, not no row
--   T930 not asked       holds bars but is not in the call: it gets no row
--   T930 moves           a later bar lands and a second call moves `last_date`; the other span is
--                        not rewritten
--
-- And: a repeated id and an id with no security do not fail the call, `anon` cannot call it, and
-- `ingest_rw` can.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.data_source (code, name) values ('yfinance', 'yfinance') on conflict do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000930a01', 'T930 old history', 'equity'),
  ('00000000-0000-0000-0000-000000930a02', 'T930 no bars',     'equity'),
  ('00000000-0000-0000-0000-000000930a03', 'T930 not asked',   'equity'),
  ('00000000-0000-0000-0000-000000930a04', 'T930 moves',       'equity');

-- Out of date order on purpose: a rule taking the first or last row WRITTEN would pick 2015 and
-- 1998, not 1998 and 2026.
insert into market.price_bar (security_id, trade_date, close, source_code) values
  ('00000000-0000-0000-0000-000000930a01', date '2015-06-01', 20, 'yfinance'),
  ('00000000-0000-0000-0000-000000930a01', date '2026-09-01', 30, 'yfinance'),
  ('00000000-0000-0000-0000-000000930a01', date '1998-03-02', 10, 'yfinance'),
  ('00000000-0000-0000-0000-000000930a03', date '2020-01-02', 10, 'yfinance'),
  ('00000000-0000-0000-0000-000000930a04', date '2026-09-10', 10, 'yfinance');

-- 1. The first call, as the worker, with a repeated id and an id that names no security.
do $$
declare r jsonb; f date; l date; n int;
begin
  set local role ingest_rw;
  r := market.derive_security_price_span(array[
    '00000000-0000-0000-0000-000000930a01', '00000000-0000-0000-0000-000000930a01',
    '00000000-0000-0000-0000-000000930a02', '00000000-0000-0000-0000-000000930a04',
    '00000000-0000-0000-0000-000000930aff']::uuid[]);
  reset role;

  if (r->>'asked')::int <> 3 or (r->>'written')::int <> 3 or (r->>'without_bars')::int <> 1 then
    raise exception 'expected 3 asked, 3 written, 1 without bars; got %', r;
  end if;

  select first_date, last_date into f, l from market.security_price_span
   where security_id = '00000000-0000-0000-0000-000000930a01';
  if f is distinct from date '1998-03-02' or l is distinct from date '2026-09-01' then
    raise exception 'the span is % .. %, not the oldest and newest bar (1998-03-02 .. 2026-09-01)', f, l;
  end if;

  select count(*) into n from market.security_price_span
   where security_id = '00000000-0000-0000-0000-000000930a02' and first_date is null and last_date is null;
  if n <> 1 then
    raise exception 'a security asked about with no bars has % null-dated rows, not 1 — "not reached" and "reached, holds nothing" must stay apart', n;
  end if;

  select count(*) into n from market.security_price_span
   where security_id = '00000000-0000-0000-0000-000000930a03';
  if n <> 0 then
    raise exception 'a security the call did not ask about got a span';
  end if;
  raise notice 'ok  the span is the oldest and newest bar, an empty answer is a row, and only the asked are written';
end $$;

-- 2. A later bar moves the span; an unchanged one is not rewritten.
insert into market.price_bar (security_id, trade_date, close, source_code) values
  ('00000000-0000-0000-0000-000000930a04', date '2026-09-11', 11, 'yfinance');

do $$
declare r jsonb; l date;
begin
  set local role ingest_rw;
  r := market.derive_security_price_span(array[
    '00000000-0000-0000-0000-000000930a01', '00000000-0000-0000-0000-000000930a02',
    '00000000-0000-0000-0000-000000930a04']::uuid[]);
  reset role;

  if (r->>'written')::int <> 1 then
    raise exception 'a second call rewrote % spans, not 1 — only the security with a new bar changed', r->>'written';
  end if;
  -- Counted over what was ASKED, not what was written: the empty security is unchanged, so it is
  -- not rewritten, and it still holds no bars.
  if (r->>'without_bars')::int <> 1 then
    raise exception 'without_bars is % on the second call, not 1 — it must count the asked securities that hold no bars, not the rows rewritten', r->>'without_bars';
  end if;
  select last_date into l from market.security_price_span
   where security_id = '00000000-0000-0000-0000-000000930a04';
  if l is distinct from date '2026-09-11' then
    raise exception 'last_date is %, not the new bar 2026-09-11', l;
  end if;
  raise notice 'ok  a new bar moves the span, and nothing else is rewritten';
end $$;

-- 3. Who may call it.
do $$
begin
  if has_function_privilege('anon', 'market.derive_security_price_span(uuid[])', 'execute') then
    raise exception 'anon can derive price spans';
  end if;
  if not has_function_privilege('ingest_rw', 'market.derive_security_price_span(uuid[])', 'execute') then
    raise exception 'the worker cannot derive price spans';
  end if;
  raise notice 'ok  the worker can derive price spans, and anon cannot';
end $$;

rollback;
