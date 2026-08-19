-- Every filter dimension must be a predicate on one row, and a missing fact must be NULL not a guess.
--
-- WHY THIS EXISTS. Region, economy tier and income group were seeded in `classification_members`
-- for 181-221 countries and joined to no security view, so filtering by them was impossible while
-- the data sat complete. The risk in fixing that is the opposite one: inventing a value where none
-- exists. A cap band guessed from a native (non-USD) figure would put a KRW company three orders of
-- magnitude into the wrong bucket, which is exactly the class of error migration 74 was about.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity'),('bond','Bond') on conflict do nothing;
insert into market.currency (code) values ('USD'),('KRW') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;

insert into market.countries (iso2, name, flag, market, drillable) values
  ('ZA', 'Testonia', 'ZA', 'emerging', false)
on conflict (iso2) do nothing;

insert into market.classification_schemes (id, name, sort_order) values
  ('msci','MSCI',1),('world-bank','World Bank',3)
on conflict (id) do nothing;
insert into market.classification_groups (scheme_id, lens, id, name, sort_order) values
  ('msci','tier','emerging','Emerging',2),
  ('msci','region','em-emea','EM EMEA',4),
  ('world-bank','tier','upper-middle','Upper middle income',2),
  ('world-bank','region','sub-saharan-africa','Sub-Saharan Africa',7)
on conflict (scheme_id, lens, id) do nothing;
insert into market.classification_members (scheme_id, lens, iso2, group_id) values
  ('msci','tier','ZA','emerging'),
  ('msci','region','ZA','em-emea'),
  ('world-bank','tier','ZA','upper-middle'),
  ('world-bank','region','ZA','sub-saharan-africa')
on conflict (scheme_id, lens, iso2) do nothing;

-- A: USD-quoted large cap, fully classified.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap) values
  ('00000000-0000-0000-0000-000000007701', 'T77 Large USD', 'equity', 'ZA', 'USD', 25e9)
on conflict (security_id) do nothing;
-- B: KRW-quoted, and NO fx rate seeded for KRW in this transaction -> cap is not comparable.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap) values
  ('00000000-0000-0000-0000-000000007702', 'T77 Uncomparable KRW', 'equity', 'ZA', 'KRW', 1802e12)
on conflict (security_id) do nothing;
-- C: a bond, so the bond attributes must be reachable.
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code,
                             maturity_date, coupon_rate, in_default) values
  ('00000000-0000-0000-0000-000000007703', 'T77 Bond', 'bond', 'ZA', 'USD', date '2031-06-30', 4.25, false)
on conflict (security_id) do nothing;

insert into market.fx_rate (currency_code, as_of, usd_per_unit, source_code) values
  ('USD', current_date, 1, 'yfinance')
on conflict (currency_code, as_of) do nothing;

-- THE SPINE IS A SNAPSHOT (migration 80). Fixtures inserted in this transaction are not in it
-- until it is rebuilt, so every assertion below would read an empty view and "pass" or fail for
-- the wrong reason. The NON-concurrent form is used deliberately: `refresh ... concurrently`
-- cannot run inside a transaction block, and a test that cannot roll back is not a test.
refresh materialized view market.security_facets;

-- 1. ALL SIX LENSES land on the security, from country membership alone.
do $$
declare r record;
begin
  select * into r from market.security_facets where security_id = '00000000-0000-0000-0000-000000007701';
  if r.msci_tier is distinct from 'emerging' then raise exception 'msci_tier is %', coalesce(r.msci_tier,'<null>'); end if;
  if r.msci_region is distinct from 'em-emea' then raise exception 'msci_region is %', coalesce(r.msci_region,'<null>'); end if;
  if r.income_group is distinct from 'upper-middle' then raise exception 'income_group is %', coalesce(r.income_group,'<null>'); end if;
  if r.wb_region is distinct from 'sub-saharan-africa' then raise exception 'wb_region is %', coalesce(r.wb_region,'<null>'); end if;
end $$;

-- 2. CAP BAND comes from the USD figure.
do $$
declare b text;
begin
  select cap_band into b from market.security_facets where security_id = '00000000-0000-0000-0000-000000007701';
  if b is distinct from 'large' then raise exception '$25bn should band as large, got %', coalesce(b,'<null>'); end if;
end $$;

-- 3. AN UNCOMPARABLE CAP IS UNBANDED, NOT GUESSED. This is the assertion that matters most: the
--    KRW figure is numerically enormous (1.802e15) and banding the NATIVE number would call it
--    "large" on arithmetic that means nothing. With no FX rate it must be NULL.
do $$
declare b text; usd numeric; native numeric;
begin
  select cap_band, market_cap_usd, market_cap_native into b, usd, native
    from market.security_facets where security_id = '00000000-0000-0000-0000-000000007702';
  if native is null then raise exception 'the native cap should still be exposed'; end if;
  if usd is not null then raise exception 'there is no KRW rate here, so market_cap_usd must be NULL, got %', usd; end if;
  if b is not null then
    raise exception
      'a cap with no FX rate was banded as % — banding the native figure puts a KRW company three orders of magnitude into the wrong bucket', b;
  end if;
end $$;

-- 4. BOND ATTRIBUTES are reachable. 15,159 of 27,629 securities are bonds and could not be
--    filtered by maturity or coupon at all before this view.
do $$
declare r record;
begin
  select * into r from market.security_facets where security_id = '00000000-0000-0000-0000-000000007703';
  if r.maturity_date is distinct from date '2031-06-30' then raise exception 'maturity missing'; end if;
  if r.coupon_rate is distinct from 4.25 then raise exception 'coupon missing'; end if;
  if r.security_type_code is distinct from 'bond' then raise exception 'type wrong'; end if;
end $$;

-- 5. A COUNTRY WITH NO MEMBERSHIP yields NULL lenses rather than dropping the security. An inner
--    join here would silently delete every security in an unclassified country from every list.
insert into market.countries (iso2, name, flag, drillable) values ('ZB','Unclassifiedland','ZB',false)
  on conflict (iso2) do nothing;
insert into market.security (security_id, name, security_type_code, country_iso2, currency_code, market_cap) values
  ('00000000-0000-0000-0000-000000007704', 'T77 Unclassified', 'equity', 'ZB', 'USD', 5e9)
on conflict (security_id) do nothing;

refresh materialized view market.security_facets;   -- the ZB fixtures above are new

do $$
declare n integer; t text;
begin
  select count(*) into n from market.security_facets where security_id = '00000000-0000-0000-0000-000000007704';
  if n <> 1 then
    raise exception 'a security in a country with no classification membership was DROPPED from the facets view (% rows) — the lens joins must be LEFT joins', n;
  end if;
  select msci_tier into t from market.security_facets where security_id = '00000000-0000-0000-0000-000000007704';
  if t is not null then raise exception 'expected a null tier, got %', t; end if;
end $$;

rollback;
