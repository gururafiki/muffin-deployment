-- THE ROTATION MUST REACH EVERY RESOURCE, AND WRAP.
--
-- This replaces the `RESOURCES=$(printf ...)` loop in market-warmup.yml, which was a plain list
-- executed top to bottom: every resource was obviously reached because the shell walked them in
-- order. A CURSOR is not obvious. It can skip one, stick on one, or drift by an off-by-one that
-- nothing reports — and the symptom would be a resource that silently never runs, which is exactly
-- the failure `exchange-listings` sat in for weeks while being registered, deployed and reachable.
--
-- `cron_next()` is deliberately PURE — it advances the cursor and returns a name, with no HTTP —
-- so this can run in CI against plain Postgres. `pg_net` and `vault` do not exist there, and a
-- combined function could only ever have been exercised in production.

\set ON_ERROR_STOP on

begin;

-- Isolate from the real seed so the test says something exact rather than "38 of 38, probably".
delete from market.cron_resource;
insert into market.cron_resource (position, resource) values
  (0, 't-alpha'), (10, 't-beta'), (20, 't-gamma'), (30, 't-delta'), (40, 't-epsilon');
update market.cron_cursor set position = -1;

do $$
declare
  n        integer;
  seen     text[] := '{}';
  got      text;
  i        integer;
begin
  select count(*) into n from market.cron_resource where enabled;

  -- One full cycle.
  for i in 1..n loop
    got := market.cron_next();
    seen := seen || got;
  end loop;

  -- EVERY resource exactly once. A set comparison, not a count: a cursor that returned
  -- 't-alpha' five times would pass a count check and be completely broken.
  if (select count(*) from (select unnest(seen) except select resource from market.cron_resource) q) > 0
     or (select count(*) from (select resource from market.cron_resource except select unnest(seen)) q) > 0 then
    raise exception 'one cycle did not visit every resource exactly once. visited: %', seen;
  end if;
  if array_length(seen, 1) <> n then
    raise exception 'expected % visits, got %', n, array_length(seen, 1);
  end if;
  raise notice '  ok  one cycle visits all % resources exactly once', n;

  -- IN POSITION ORDER, not merely all of them. The order is semantic: the seed puts
  -- `security-yahoo-symbols` BEFORE every resource that consumes symbols, because a symbol it
  -- resolves clears that security's negative caches and the later passes then pick it up in the
  -- SAME sweep instead of waiting a day. A rotation that visits everything in an arbitrary order
  -- satisfies every other assertion here and quietly loses that.
  if seen <> (select array_agg(resource order by position) from market.cron_resource where enabled) then
    raise exception 'the rotation did not follow `position` order. got %, expected %',
      seen, (select array_agg(resource order by position) from market.cron_resource where enabled);
  end if;
  raise notice '  ok  and it follows the seeded position order';

  -- And it WRAPS rather than stopping or running off the end.
  got := market.cron_next();
  if got <> seen[1] then
    raise exception 'the rotation did not wrap: expected %, got %', seen[1], got;
  end if;
  raise notice '  ok  the rotation wraps back to the first resource';
end $$;

-- DISABLING ONE MUST SHRINK THE CYCLE. The modulo is over `count(*) where enabled`, so a disabled
-- resource has to drop out — otherwise `enabled` is decorative and a resource that is failing
-- cannot be taken out of rotation without a migration.
update market.cron_resource set enabled = false where resource = 't-gamma';
update market.cron_cursor set position = -1;

do $$
declare seen text[] := '{}'; i integer;
begin
  -- EIGHT ticks, not four. If the modulo counted ALL resources while the lookup filtered to the
  -- enabled ones, position 4 would find no row and return NULL — and that only happens on the
  -- FIFTH tick. A four-tick test passes against exactly that bug, which mutation testing proved
  -- by shipping it: the first version of this block missed it.
  for i in 1..8 loop seen := seen || market.cron_next(); end loop;

  if 't-gamma' = any(seen) then
    raise exception 'a DISABLED resource was still scheduled: %', seen;
  end if;
  -- A NULL is the signature of a modulo wider than the lookup.
  if array_position(seen, null) is not null then
    raise exception 'the rotation returned NULL — the modulo is wider than the enabled set: %', seen;
  end if;
  if (select count(distinct x) from unnest(seen) x) <> 4 then
    raise exception 'disabling one resource did not shrink the cycle to 4 distinct: %', seen;
  end if;
  raise notice '  ok  a disabled resource drops out; 8 ticks cover exactly 4 distinct, no NULLs';
end $$;

rollback;
