-- A line the venue directory stopped returning is offered by nothing and derived by nothing, and a
-- line's last sighting never moves backwards.
--
-- WHY. `venue_listing` only grows, so without `absent_since` a delisted company stays "listed, not
-- tracked" in the Markets search for ever, the Track button mints a security for it, and the
-- listing derivation keeps it as a tracked security's line. Migration 20261004120000.
--
-- Each absent fixture line would pass every OTHER rule of its reader, so the mark is the only thing
-- excluding it, and each has a present twin that must survive:
--
--   T1004 untracked   a named, unidentified line: the search offers the present one only
--   T1004 tracked     two lines of one tracked share class: only the present one is derived, and
--                     the absent one is retracted although it was derived before
--   T1004 track       the Track RPC refuses the absent line, as an admin, and promotes its twin
--   T1004 sighting    an older `last_seen_at` written over a newer one leaves the newer

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.identifier_kind (code, name, is_global_unique)
values ('share_class_figi', 'OpenFIGI share-class FIGI', true) on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZU', 'Homeland', 'ZU', false)
on conflict (iso2) do nothing;
insert into market.exchange (exch_code, country_iso2, suffix, preference) values ('T4A', 'ZU', '.ZA', 1)
on conflict (exch_code) do nothing;

insert into market.venue_listing
       (figi, composite_figi, exch_code, ticker, name, provider_symbol, share_class_figi,
        last_seen_at, absent_since) values
  ('BBGT1004U1', 'BBGT1004U1', 'T4A', 'TUA', 'T1004 untracked present', 'TUA.ZA', null,
   now(), null),
  ('BBGT1004U2', 'BBGT1004U2', 'T4A', 'TUB', 'T1004 untracked absent',  'TUB.ZA', null,
   now() - interval '40 days', now()),
  ('BBGT1004P1', 'BBGT1004P1', 'T4A', 'TPA', 'T1004 tracked',           'TPA.ZA', 'T1004CLS',
   now(), null),
  ('BBGT1004P2', 'BBGT1004P2', 'T4A', 'TPB', 'T1004 tracked',           'TPB.ZA', 'T1004CLS',
   now() - interval '40 days', now());

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000001004', 'T1004 tracked', 'equity', 'ZU');
insert into market.security_identifier (kind_code, value, security_id) values
  ('share_class_figi', 'T1004CLS', '00000000-0000-0000-0000-000000001004');
-- DERIVED BEFORE IT WENT ABSENT: the derivation must retract it, not merely skip it.
insert into market.security_listing (figi, security_id) values
  ('BBGT1004P2', '00000000-0000-0000-0000-000000001004');

-- 1. The search offers the present line and not the absent one.
do $$
begin
  if not exists (select 1 from market.untracked_listing where figi = 'BBGT1004U1') then
    raise exception 'the present untracked line is not offered: the fixture proves nothing';
  end if;
  if exists (select 1 from market.untracked_listing where figi = 'BBGT1004U2') then
    raise exception 'a line the directory stopped returning is offered as untracked';
  end if;
end $$;

-- 2. Only the present line of a tracked class is a listing.
select market.derive_security_listing();
do $$
begin
  if not exists (select 1 from market.security_listing where figi = 'BBGT1004P1') then
    raise exception 'the present line of a tracked class was not derived';
  end if;
  if exists (select 1 from market.security_listing where figi = 'BBGT1004P2') then
    raise exception 'an absent line is still a listing of a tracked security';
  end if;
end $$;

-- 3. The Track button refuses the absent line and promotes its present twin.
set local request.jwt.claims = '{"sub":"admin-x","app_metadata":{"role":"admin"}}';
do $$
declare r jsonb;
begin
  r := market.promote_listing('BBGT1004U2');
  if not (r ->> 'promoted' = 'false' and r ->> 'reason' like 'the venue directory has not returned%') then
    raise exception 'an absent line was promoted, or refused for another reason: %', r;
  end if;
  r := market.promote_listing('BBGT1004U1');
  if not (r ->> 'promoted' = 'true') then
    raise exception 'the present twin was refused: %', r;
  end if;
end $$;

-- 4. A sighting never moves backwards, and a newer one moves forward.
do $$
declare
  newest timestamptz;
begin
  select last_seen_at into newest from market.venue_listing where figi = 'BBGT1004P1';
  update market.venue_listing set last_seen_at = newest - interval '30 days' where figi = 'BBGT1004P1';
  if (select last_seen_at from market.venue_listing where figi = 'BBGT1004P1') <> newest then
    raise exception 'an older sighting overwrote a newer one';
  end if;
  update market.venue_listing set last_seen_at = newest + interval '1 day' where figi = 'BBGT1004P1';
  if (select last_seen_at from market.venue_listing where figi = 'BBGT1004P1') <> newest + interval '1 day' then
    raise exception 'a newer sighting did not move last_seen_at forward';
  end if;
end $$;

rollback;
