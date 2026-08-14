-- Migration 58 promotes a market cap out of the fundamentals payload, and only where it should.
--
-- WHY THIS EXISTS AS A TEST. Another repair whose `update` matches zero rows on an empty database.
-- The behaviour that matters is entirely in the predicates: `raw` is free-form jsonb written by a
-- provider, so `market_cap` may be absent, null, zero, or a STRING — and the two string cases fail
-- DIFFERENTLY, which is why both are here. A numeric-looking string ("234915282944") casts fine and
-- would be promoted, quietly accepting a type the column contract does not want; a non-numeric one
-- ("n/a", which providers do emit) RAISES, and the migration set is applied `--single-transaction`,
-- so that aborts the whole deploy. `jsonb_typeof(...) = 'number'` is what declines both.
--
-- And the half that makes it a promotion rather than an overwrite: a security that ALREADY has a
-- cap keeps it. The resource's own value is newer than a jsonb payload of unknown age.

\set ON_ERROR_STOP on

begin;

insert into market.data_source (code, name) values ('yfinance', 'yfinance')
on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code, market_cap) values
  ('00000000-0000-0000-0000-0000000058a1', 'T58 Promotable',  'equity', null),
  ('00000000-0000-0000-0000-0000000058a2', 'T58 Has a cap',   'equity', 999),
  ('00000000-0000-0000-0000-0000000058a3', 'T58 Cap is text', 'equity', null),
  ('00000000-0000-0000-0000-0000000058a4', 'T58 Cap is zero', 'equity', null),
  ('00000000-0000-0000-0000-0000000058a5', 'T58 No cap key',  'equity', null),
  ('00000000-0000-0000-0000-0000000058a6', 'T58 Cap is null', 'equity', null),
  ('00000000-0000-0000-0000-0000000058a7', 'T58 Cap is n/a',  'equity', null)
on conflict (security_id) do nothing;

insert into market.security_fundamentals (security_id, source_code, as_of, raw) values
  ('00000000-0000-0000-0000-0000000058a1', 'yfinance', now(), '{"market_cap": 234915282944}'),
  ('00000000-0000-0000-0000-0000000058a2', 'yfinance', now(), '{"market_cap": 5000}'),
  -- A provider that quotes a number is not hypothetical; PostgREST does it for `numeric`. This one
  -- casts CLEANLY, so without the type guard it is promoted — a wrong value, not a loud failure.
  ('00000000-0000-0000-0000-0000000058a3', 'yfinance', now(), '{"market_cap": "234915282944"}'),
  ('00000000-0000-0000-0000-0000000058a4', 'yfinance', now(), '{"market_cap": 0}'),
  ('00000000-0000-0000-0000-0000000058a5', 'yfinance', now(), '{"beta": 1.1}'),
  ('00000000-0000-0000-0000-0000000058a6', 'yfinance', now(), '{"market_cap": null}'),
  -- The one that does not merely write a wrong value but ABORTS the deploy if the type guard goes.
  ('00000000-0000-0000-0000-0000000058a7', 'yfinance', now(), '{"market_cap": "n/a"}')
on conflict (security_id) do nothing;

delete from market.one_shot where key = '58-promote-market-cap-from-fundamentals';

\i stack/supabase/migrations/58-the-market-cap-was-already-here.sql

do $$
declare
  bad text;
begin
  select string_agg(format('%s: market_cap %s, expected %s',
                           s.name, coalesce(s.market_cap::text, '<null>'), e.want), '; ')
    into bad
  from market.security s
  join (values
    ('00000000-0000-0000-0000-0000000058a1'::uuid, '234915282944'),
    -- Kept: the resource's own value outranks a payload of unknown age.
    ('00000000-0000-0000-0000-0000000058a2'::uuid, '999'),
    -- Declined, all five, rather than cast or written as a bad number.
    ('00000000-0000-0000-0000-0000000058a3'::uuid, '<null>'),
    ('00000000-0000-0000-0000-0000000058a4'::uuid, '<null>'),
    ('00000000-0000-0000-0000-0000000058a5'::uuid, '<null>'),
    ('00000000-0000-0000-0000-0000000058a6'::uuid, '<null>'),
    ('00000000-0000-0000-0000-0000000058a7'::uuid, '<null>')
  ) e(security_id, want) on e.security_id = s.security_id
  where coalesce(s.market_cap::text, '<null>') is distinct from e.want;

  if bad is not null then
    raise exception 'migration 58 promoted the wrong caps: %', bad;
  end if;
  raise notice 'ok  a numeric cap is promoted; a string, zero, null, absent or existing one is not';
end $$;

rollback;
