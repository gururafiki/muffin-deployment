-- `promote_listing` refuses a non-admin, promotes for an admin, needs the directory, and treats
-- an already-held listing as a no-op.
--
-- WHY A BEHAVIOURAL TEST AND NOT A REVIEW. The function is SECURITY DEFINER — the caller is a
-- signed-in user, and only the definer can write `market.*` — so its one guard is the JWT claim,
-- not RLS. A gate written as the obvious negation of "is admin" FAILS OPEN on a caller with no
-- claims at all (NULL <> 'admin' is NULL, not true); the whole point of this test is to prove the
-- gate holds for the three states a token can be in.
--
-- Run by the `migrations` job in quality.yml AFTER the two application passes. The dotted GUC is
-- settable because Postgres permits custom parameters with a dot in the name.

\set ON_ERROR_STOP on

begin;

insert into market.venue_listing (figi, composite_figi, exch_code, ticker, name, provider_symbol)
values ('BBG000B9XBU4', 'BBG000B9XBU4', 'AU', 'SWP', 'Swoop Holdings Ltd', 'SWP.AX');

-- 1. NO JWT AT ALL IS NOT AN ADMIN. The claims GUC is unset, so `request.jwt.claims` is NULL —
-- and the gate must COALESCE that to false, not let `NULL = 'admin'` fall through.
select current_setting('request.jwt.claims', true) is null as no_claims;
do $$
declare r jsonb;
begin
  r := market.promote_listing('BBG000B9XBU4');
  if not (r ->> 'promoted' = 'false' and r ->> 'reason' = 'admins only') then
    raise exception 'no JWT promoted a listing: %', r;
  end if;
end $$;

-- 2. A PLAIN USER IS NOT AN ADMIN.
set local request.jwt.claims = '{"sub":"user-x","app_metadata":{"role":"user"}}';
do $$
declare r jsonb;
begin
  r := market.promote_listing('BBG000B9XBU4');
  if not (r ->> 'promoted' = 'false' and r ->> 'reason' = 'admins only') then
    raise exception 'a non-admin promoted a listing: %', r;
  end if;
end $$;

-- 3. AN ADMIN PROMOTES, AND THE LISTING BECOMES OURS.
set local request.jwt.claims = '{"sub":"admin-x","app_metadata":{"role":"admin"}}';
do $$
declare r jsonb;
       v_sid uuid;
begin
  r := market.promote_listing('BBG000B9XBU4');
  if not (r ->> 'promoted' = 'true') then
    raise exception 'an admin was refused: %', r;
  end if;
  v_sid := (r ->> 'securityId')::uuid;
  if not exists (select 1 from market.security where security_id = v_sid and name = 'Swoop Holdings Ltd') then
    raise exception 'the promoted security was not created';
  end if;
  if not exists (select 1 from market.security_identifier
                  where kind_code = 'figi' and value = 'BBG000B9XBU4' and security_id = v_sid) then
    raise exception 'the figi identifier was not created';
  end if;
  if not exists (select 1 from market.security_provider_symbol
                  where security_id = v_sid and provider_code = 'yfinance' and symbol = 'SWP.AX') then
    raise exception 'the provider symbol was not created';
  end if;
end $$;

-- 4. ALREADY OURS IS A NO-OP, NOT AN ERROR.
set local request.jwt.claims = '{"sub":"admin-x","app_metadata":{"role":"admin"}}';
do $$
declare r jsonb;
begin
  r := market.promote_listing('BBG000B9XBU4');
  if not (r ->> 'promoted' = 'false' and r ->> 'reason' = 'already tracked') then
    raise exception 'a second promotion was not a no-op: %', r;
  end if;
end $$;

-- 5. A FIGI THE SWEEP HAS NOT CATALOGUED IS REFUSED, HONESTLY — the fallback is gone.
set local request.jwt.claims = '{"sub":"admin-x","app_metadata":{"role":"admin"}}';
do $$
declare r jsonb;
begin
  r := market.promote_listing('BBG999999999');
  if not (r ->> 'promoted' = 'false' and r ->> 'reason' like 'unknown figi%') then
    raise exception 'an unknown figi was promoted or misreported: %', r;
  end if;
end $$;

rollback;
