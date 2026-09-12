-- TWO SECURITIES MUST NOT SHARE A DISPLAY SYMBOL, AND SINCE THE D2 CUTOVER NOTHING ENFORCES IT.
--
-- `market.performance` was a TABLE with `PRIMARY KEY (scope, scope_id, period)`, so a symbol
-- collision was impossible by construction: two securities resolving to one `scope_id` collapsed
-- into a single row at write time. As a VIEW over `security_return` joined to `security_symbol`
-- that guarantee is gone — a collision renders TWO rows for one `(scope, scope_id, period)`, and
-- every consumer of `performance` assumes that tuple is unique.
--
-- The cutover therefore moved an ENFORCED invariant into an ASSUMED one, which is precisely the
-- kind of change that is invisible until it is expensive. This is the replacement enforcement.
--
-- IT IS NOT HYPOTHETICAL. It was found when a fixture in `a-filtered-aggregate-must-recompute.sql`
-- seeded synthetic instruments called `CCC` and `DDD` — both real listed tickers — and the
-- cap-weighted mean under test came out 18.4576 against an expected 6.6667, because a stranger's
-- returns had been averaged in. Nothing errored; the number was simply wrong.
--
-- Production is clean today: measured 2026-09-12, **0 symbols shared across 11,716 securities**.
-- The point of the check is that it stays that way — a promoted listing or a second venue is
-- exactly how it would stop being true.

\set ON_ERROR_STOP on

begin;

do $$
declare n int; worst text;
begin
  select count(*), coalesce(max(symbol), '-') into n, worst
    from (select symbol from market.security_symbol group by symbol having count(*) > 1) t;

  if n > 0 then
    raise exception
      '% display symbol(s) are claimed by more than one security (e.g. %) — `market.performance` '
      'renders one row per security, so every consumer reading (scope, scope_id, period) as unique '
      'now sees duplicates and any weighted mean over it is wrong',
      n, worst;
  end if;
  raise notice '  ok  every display symbol belongs to exactly one security';
end $$;

-- AND THE GUARD MUST BE ABLE TO FIRE, or it is a comment. Seeded inside the transaction so the
-- assertion above is proven reachable rather than merely passing on clean data.
insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZU','Uniqueland','ZU',false)
  on conflict (iso2) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('test','Test fixture',1)
  on conflict (code) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-0000000f0001'::uuid,'U1','equity','ZU'),
  ('00000000-0000-0000-0000-0000000f0002'::uuid,'U2','equity','ZU')
on conflict (security_id) do nothing;
-- THROUGH THE LISTING, NOT THE IDENTIFIER. `security_identifier` is `PRIMARY KEY (kind, value)`,
-- so two securities cannot share a ticker there — the first attempt at this fixture inserted the
-- duplicate, had it silently dropped by `on conflict do nothing`, and the self-test below caught a
-- guard that was asserting nothing. `security_symbol` resolves the PRIMARY LISTING's
-- `provider_symbol` first, and nothing stops two listings on different venues carrying one symbol.
insert into market.exchange (exch_code, country_iso2, suffix) values
  ('ZU1','ZU','.ZU1'), ('ZU2','ZU','.ZU2')
on conflict (exch_code) do nothing;
insert into market.listing (security_id, exch_code, symbol, provider_symbol, is_primary, source_code)
values ('00000000-0000-0000-0000-0000000f0001'::uuid,'ZU1','ZZUNIQ','ZZUNIQ',true,'test'),
       ('00000000-0000-0000-0000-0000000f0002'::uuid,'ZU2','ZZUNIQ','ZZUNIQ',true,'test')
on conflict do nothing;

do $$
declare n int;
begin
  select count(*) into n
    from (select symbol from market.security_symbol group by symbol having count(*) > 1) t;
  if n = 0 then
    raise exception 'the guard cannot see a collision that was deliberately created — it is '
                    'asserting nothing, which is worse than not existing';
  end if;
  raise notice '  ok  and the guard fires on a deliberately seeded collision (% symbol(s))', n;
end $$;

rollback;
