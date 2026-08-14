-- The app must show where a company OPERATES, while keeping where it is INCORPORATED.
--
-- WHY THIS EXISTS AS A TEST. Migration 56 changes an expression inside two views, and an empty
-- database exercises neither: with no securities, `coalesce(provider_country_iso2, country_iso2)`
-- is never evaluated and the migration passes while doing nothing. The failure this guards against
-- is silent by construction — a security simply appears under the wrong country page, which no
-- count and no floor can see.
--
-- The case it is built from is real. Alibaba files under `KY` because N-PORT reports the
-- INCORPORATION jurisdiction; there is no Cayman Islands market page, so it was reachable only
-- through the "Other" bucket. 180 equities sit in venue-less jurisdictions this way.
--
-- Four behaviours, and the last two are the ones most likely to be lost in a later edit:
--
--   1. operating country wins            filed KY + provider CN -> CN
--   2. filed country is the fallback     filed US + no provider  -> US
--   3. the filed value SURVIVES          filed_country_iso2 still reads KY, or the domicile
--                                        question becomes unanswerable
--   4. the display NAME follows the code  country_name must say China, not Cayman Islands —
--                                        the join moved with the expression, and a stale join
--                                        prints a country that disagrees with the code beside it

\set ON_ERROR_STOP on

begin;

insert into market.countries (iso2, name, flag, region_id, market, drillable) values
  ('KY', 'Cayman Islands', 'KY', 'americas', 'frontier', false)
on conflict (iso2) do nothing;

insert into market.security
  (security_id, name, security_type_code, country_iso2, provider_country_iso2) values
  -- The Alibaba shape: incorporated offshore, operating in a real market.
  ('00000000-0000-0000-0000-0000000056a1', 'T56 Offshore Co', 'equity', 'KY', 'CN'),
  -- No provider country yet (the backlog has not reached it). The filing must still answer.
  ('00000000-0000-0000-0000-0000000056a2', 'T56 Domestic Co', 'equity', 'US', null),
  -- Neither. Must stay null rather than inventing a country.
  ('00000000-0000-0000-0000-0000000056a3', 'T56 Unknown Co',  'equity', null, null)
on conflict (security_id) do nothing;

do $$
declare
  bad text;
begin
  select string_agg(format('%s: country=%s name=%s filed=%s, expected country=%s filed=%s',
                           v.name, coalesce(v.country_iso2,'<null>'), coalesce(v.country_name,'<null>'),
                           coalesce(v.filed_country_iso2,'<null>'), e.want_iso, coalesce(e.want_filed,'<null>')), '; ')
    into bad
  from market.security_current v
  join (values
    ('00000000-0000-0000-0000-0000000056a1'::uuid, 'CN',     'KY'),
    ('00000000-0000-0000-0000-0000000056a2'::uuid, 'US',     'US'),
    ('00000000-0000-0000-0000-0000000056a3'::uuid, '<null>', null)
  ) e(security_id, want_iso, want_filed) on e.security_id = v.security_id
  where coalesce(v.country_iso2, '<null>') is distinct from e.want_iso
     or v.filed_country_iso2 is distinct from e.want_filed;

  if bad is not null then
    raise exception 'security_current does not report the operating country: %', bad;
  end if;
  raise notice 'ok  operating country wins, filed country survives, neither is invented';
end $$;

-- 4. The display name must follow the effective code. This is a separate assertion because the
--    join is a separate expression from the coalesce, and leaving it on `s.country_iso2` yields a
--    row reading `country_iso2 = CN, country_name = Cayman Islands` — internally inconsistent and
--    invisible to any check that only looks at the code.
do $$
declare
  got text;
begin
  select country_name into got from market.security_current
   where security_id = '00000000-0000-0000-0000-0000000056a1';
  if got is distinct from 'China' then
    raise exception 'country_name is %, expected China — the display join did not move with the '
                    'coalesce, so the name disagrees with the code beside it', coalesce(got,'<null>');
  end if;
  raise notice 'ok  the country NAME follows the effective code';
end $$;

rollback;
