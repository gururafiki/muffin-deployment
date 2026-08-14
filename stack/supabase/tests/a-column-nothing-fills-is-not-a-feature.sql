-- `pending_profile` must ASK for a security that has a sector but no placeable country.
--
-- WHY THIS EXISTS AS A TEST, and it is the sharpest lesson of the change it guards. Migration 56
-- added `provider_country_iso2`, the resource wrote it correctly, `deno check` passed, three
-- migration passes passed, and production sat at ZERO rows populated — because the only backlog
-- that drives the resource asks for securities with no SECTOR, and that backlog was drained. The
-- population that needed the new column was exactly the population the backlog had finished with.
--
-- Nothing in the pipeline could have reported this. `security-profiles` answered "every security
-- has a sector" and returned success, which is true and useless. It was found by measuring the
-- column after the deploy.
--
-- So the invariant is not "the resource writes the column" — that was already true — but **the
-- backlog asks for it**. Four cases, and each of the last three is a way the fix could be too
-- greedy or too shy:
--
--   1. sector + offshore incorporation   -> ASKED   (the Alibaba case, KY/BM/MH; 384 securities)
--   2. sector + drillable country        -> not asked (11k securities; asking would spend eighteen
--                                          runs of the rate limit to change nothing)
--   3. already has a provider country    -> not asked (answered once, done)
--   4. negative-cached                   -> not asked (or it re-asks for ever, the failure this
--                                          schema has rediscovered five times)

\set ON_ERROR_STOP on

begin;

insert into market.countries (iso2, name, flag, region_id, market, drillable) values
  ('KY', 'Cayman Islands', 'KY', 'americas', 'frontier', false)
on conflict (iso2) do update set drillable = false;
insert into market.countries (iso2, name, flag, region_id, market, drillable) values
  ('US', 'United States', 'US', 'americas', 'developed', true)
on conflict (iso2) do update set drillable = true;

insert into market.data_source (code, name) values ('yfinance', 'yfinance')
on conflict (code) do nothing;

insert into market.security
  (security_id, name, security_type_code, country_iso2, provider_country_iso2, provider_country_missing_at) values
  ('00000000-0000-0000-0000-0000000059a1', 'T59 Offshore',       'equity', 'KY', null, null),
  ('00000000-0000-0000-0000-0000000059a2', 'T59 Placeable',      'equity', 'US', null, null),
  ('00000000-0000-0000-0000-0000000059a3', 'T59 Already homed',  'equity', 'KY', 'US',  null),
  ('00000000-0000-0000-0000-0000000059a4', 'T59 Asked already',  'equity', 'KY', null, now()),
  ('00000000-0000-0000-0000-0000000059a5', 'T59 No country',     'equity', null, null, null)
on conflict (security_id) do nothing;

-- Every one of them HAS a sector, so none qualifies under the original "no sector" reason. That is
-- the whole point: before this change the backlog was empty for all five.
insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-0000000059a1', 'ticker', 'T59A'),
  ('00000000-0000-0000-0000-0000000059a2', 'ticker', 'T59B'),
  ('00000000-0000-0000-0000-0000000059a3', 'ticker', 'T59C'),
  ('00000000-0000-0000-0000-0000000059a4', 'ticker', 'T59D'),
  ('00000000-0000-0000-0000-0000000059a5', 'ticker', 'T59E')
on conflict (kind_code, value) do nothing;

insert into market.security_taxonomy (security_id, node_id, source_code, as_of)
select s.security_id, n.node_id, 'yfinance', now()
from (values
  ('00000000-0000-0000-0000-0000000059a1'::uuid),
  ('00000000-0000-0000-0000-0000000059a2'::uuid),
  ('00000000-0000-0000-0000-0000000059a3'::uuid),
  ('00000000-0000-0000-0000-0000000059a4'::uuid),
  ('00000000-0000-0000-0000-0000000059a5'::uuid)
) s(security_id)
cross join lateral (
  select node_id from market.taxonomy_node
   where taxonomy_id = 'muffin' and level = 1 limit 1
) n
on conflict (security_id, node_id, source_code) do nothing;

do $$
declare
  bad text;
begin
  select string_agg(format('%s: %s, expected %s', e.name,
                           case when p.security_id is null then 'not asked' else 'asked' end,
                           e.want), '; ')
    into bad
  from (values
    ('00000000-0000-0000-0000-0000000059a1'::uuid, 'T59 Offshore',      'asked'),
    ('00000000-0000-0000-0000-0000000059a2'::uuid, 'T59 Placeable',     'not asked'),
    ('00000000-0000-0000-0000-0000000059a3'::uuid, 'T59 Already homed', 'not asked'),
    ('00000000-0000-0000-0000-0000000059a4'::uuid, 'T59 Asked already', 'not asked'),
    ('00000000-0000-0000-0000-0000000059a5'::uuid, 'T59 No country',    'asked')
  ) e(security_id, name, want)
  left join market.pending_profile p on p.security_id = e.security_id
  where (case when p.security_id is null then 'not asked' else 'asked' end)
        is distinct from e.want;

  if bad is not null then
    raise exception 'pending_profile does not ask for the right securities: %', bad;
  end if;
  raise notice 'ok  the backlog asks for an unplaceable country, and only for that';
end $$;

rollback;
