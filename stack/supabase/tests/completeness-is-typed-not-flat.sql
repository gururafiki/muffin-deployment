-- COMPLETENESS MUST BE TYPED, OR 55% OF THE UNIVERSE IS PERMANENTLY INCOMPLETE.
--
-- Measured on the node 2026-08-27: of 27,629 securities, **15,159 are BONDS** and 12,350 are
-- equities. A bond arrives from an N-PORT filing and that is all it will ever be — it has no
-- sector, no P/E and no price series here. A single flat definition of "fully ingested" would
-- report the majority of the universe as broken for facets that can never apply to it, and the
-- number would be ignored within a week.
--
-- So `market.required_facet` decides per TYPE, and this test pins the distinction that makes it
-- worth having: the SAME missing facet must count against an equity and not against a bond. If
-- both behave the same way, the control table is decorative and can be deleted without anything
-- going red.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity'), ('bond','Bond')
  on conflict (code) do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZC','Coverageland','ZC',false)
  on conflict (iso2) do nothing;

-- Two securities, IDENTICAL in what they lack: no sector, no price, no statements — nothing at
-- all beyond existing. They differ only by type.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000013101','T131 Equity','equity','ZC'),
  ('00000000-0000-0000-0000-000000013102','T131 Bond','bond','ZC')
on conflict (security_id) do nothing;

-- The spine is a MATERIALIZED view, so rows inserted in this transaction are invisible until it
-- is rebuilt. Non-concurrently on purpose: `refresh ... concurrently` cannot run inside a
-- transaction block, and a test that cannot roll back is not a test.
refresh materialized view market.security_facets;

do $$
declare
  eq_complete boolean;
  bd_complete boolean;
begin
  select (complete = securities) into eq_complete
    from market.coverage_current
   where dimension = 'security_type' and bucket = 'equity' and security_type_code = 'equity';

  select (complete = securities) into bd_complete
    from market.coverage_current
   where dimension = 'security_type' and bucket = 'bond' and security_type_code = 'bond';

  -- The equity owes nine facets and has none of them.
  if eq_complete is not false then
    raise exception 'an equity with no sector, price or statements is being counted COMPLETE '
                    '(complete=%): required_facet is not being applied', eq_complete;
  end if;

  -- The bond owes nothing, so lacking the same facets costs it nothing.
  if bd_complete is not true then
    raise exception 'a bond is being counted INCOMPLETE for facets a bond can never have '
                    '(complete=%): the definition is flat, not typed', bd_complete;
  end if;

  raise notice '  ok  the same missing facets make an equity incomplete and leave a bond complete';
end $$;

-- AND THE CONTROL TABLE IS WHAT DECIDES IT. Requiring a sector of bonds must flip the bond —
-- otherwise the rows above are read from somewhere else and `required_facet` is decorative.
insert into market.required_facet (security_type_code, facet) values ('bond','sector')
  on conflict do nothing;

do $$
declare bd_complete boolean;
begin
  select (complete = securities) into bd_complete
    from market.coverage_current
   where dimension = 'security_type' and bucket = 'bond' and security_type_code = 'bond';

  if bd_complete is not false then
    raise exception 'adding a required facet for bonds did not change their completeness '
                    '(complete=%): coverage_current is not reading required_facet', bd_complete;
  end if;
  raise notice '  ok  adding a row to required_facet moves the number — the table is load-bearing';
end $$;

rollback;
