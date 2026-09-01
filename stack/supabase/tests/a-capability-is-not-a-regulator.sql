-- WHETHER A SECURITY *CAN* HAVE SEGMENTS IS NOT "DOES IT FILE WITH SEC".
--
-- WHY. Migration 160 measured segment coverage against a `sec_filer` dimension — "does this have a
-- CIK". That is the same question as "can this have segments" only while SEC is the sole source,
-- and Korea's DART is already measured viable through the same parser and the same axes. The day
-- it ships, Korean companies would hold segments while reading `sec_filer = no`, so the denominator
-- would be measuring the wrong thing while looking correct.
--
-- THREE STATES, NOT TWO, and the middle one is the point. `resolvable` — its jurisdiction has an
-- ENABLED source but no filer id is held yet — is the addressable backlog. Without it a Korean
-- company and a Cayman shell are the same "no", and one of those absences is permanent.
--
-- THE FIXTURE MAKES THE RULES DISAGREE. Three securities: a US filer with a CIK, a Korean company
-- with none, and a Cayman shell. Under "has a CIK" the last two are identical; under capability
-- they differ the moment DART is enabled — which the test does, and undoes.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values
  ('KR','Korea, Republic of','KR',true), ('KY','Cayman Islands','KY',false),
  ('US','United States','US',true)
on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2, cik) values
  ('00000000-0000-0000-0000-000000016301','T163 US Filer','equity','US', 1630001),
  ('00000000-0000-0000-0000-000000016302','T163 Korean', 'equity','KR', null),
  ('00000000-0000-0000-0000-000000016303','T163 Shell',  'equity','KY', null)
on conflict (security_id) do nothing;

-- `coverage_current` reads `security_facets`, which is MATERIALIZED — rows inserted in this
-- transaction are invisible to it until the spine is rebuilt, so assertion 4 below would fail for
-- a reason unrelated to its subject. Non-concurrently: `refresh ... concurrently` cannot run inside
-- a transaction block, and a test that cannot roll back is not a test.
refresh materialized view market.security_facets;

do $$
declare cap_us text; cap_kr text; cap_ky text; src_kr text; n int;
begin
  -- 1. A CIK WRITTEN AT RUNTIME MUST RESOLVE IMMEDIATELY. The backfill in migration 163 runs at
  --    DEPLOY time; `sec-cik-map` writes `security.cik` on a schedule. Without the trigger, a
  --    company that lists tomorrow reads `none` until the next deploy, with the data needed to
  --    fetch its filings sitting in the next column. That is why this is a trigger and not a rule
  --    each writer must remember — the same reasoning that made `derived_at` one.
  select capability into cap_us from market.security_disclosure
   where security_id = '00000000-0000-0000-0000-000000016301';
  if cap_us <> 'held' then
    raise exception 'a security inserted WITH a cik reads % rather than held — security_filer is not being kept in step with security.cik', cap_us;
  end if;

  -- 2. WITH NO NON-SEC SOURCE ENABLED, the Korean company and the shell are both unreachable, and
  --    that is correct: an enabled source with no resource behind it would report an addressable
  --    backlog nothing can address.
  select capability into cap_kr from market.security_disclosure where security_id = '00000000-0000-0000-0000-000000016302';
  select capability into cap_ky from market.security_disclosure where security_id = '00000000-0000-0000-0000-000000016303';
  if cap_kr <> 'none' or cap_ky <> 'none' then
    raise exception 'with every non-SEC source disabled, KR reads % and KY reads % — both must be none, or a disabled source advertises work that cannot be done', cap_kr, cap_ky;
  end if;

  -- 3. ENABLING DART SEPARATES THEM. This is the assertion the old yes/no model could not make.
  update market.disclosure_source set enabled = true where code = 'dart';
  select capability, segment_source into cap_kr, src_kr from market.security_disclosure
   where security_id = '00000000-0000-0000-0000-000000016302';
  select capability into cap_ky from market.security_disclosure where security_id = '00000000-0000-0000-0000-000000016303';
  if cap_kr <> 'resolvable' or src_kr <> 'dart' then
    raise exception 'with DART enabled the Korean company reads %/% rather than resolvable/dart — a jurisdiction with a working source is addressable backlog, not absence', cap_kr, coalesce(src_kr,'null');
  end if;
  if cap_ky <> 'none' then
    raise exception 'the Cayman shell reads % — no source covers KY, so its absence is PERMANENT and must not be counted as backlog', cap_ky;
  end if;

  -- 4. THE SAME FACT LIVES IN TWO PLACES AND THEY MUST AGREE. `security.cik` is still written by
  --    `sec-cik-map` and read by five resources; `security_filer` is what capability resolves
  --    through. This schema has been bitten by exactly this before — the venue map drifted to 54
  --    rows against 38 — and the rule there was that where a fact genuinely must exist twice, BOTH
  --    are asserted. Migrating the readers off `cik` is Phase 3 work; until then this is the guard.
  select count(*) into n
    from market.security s
    left join market.security_filer f
      on f.security_id = s.security_id and f.source_code = 'sec'
   where (s.cik is not null and f.filer_id is distinct from s.cik::text)
      or (s.cik is null and f.security_id is not null);
  if n <> 0 then
    raise exception '% securities disagree between security.cik and security_filer — the trigger is not covering every write path, and capability would read from a stale registration', n;
  end if;

  -- A CLEARED CIK MUST RETRACT, or the security keeps reading `held` against a registration we no
  -- longer believe in. An upsert cannot retract; the trigger deletes.
  update market.security set cik = null where security_id = '00000000-0000-0000-0000-000000016301';
  if exists (select 1 from market.security_filer
              where security_id = '00000000-0000-0000-0000-000000016301' and source_code = 'sec') then
    raise exception 'clearing a cik left the filer row behind — the security still reads as addressable by SEC';
  end if;
  update market.security set cik = 1630001 where security_id = '00000000-0000-0000-0000-000000016301';

  -- 5. And the coverage dimension must carry all three, or the panel cannot ask the question.
  select count(distinct bucket) into n from market.coverage_current where dimension = 'segment_source';
  if n < 2 then
    raise exception 'the segment_source dimension produced % bucket(s) — it must name the regulator, not collapse to a boolean', n;
  end if;
end $$;

rollback;

\echo 'ok: capability names the regulator, separates resolvable from permanent absence, and follows a runtime CIK'
