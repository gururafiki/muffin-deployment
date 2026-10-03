-- THE HISTORY FACETS READ THE PRICE SPAN, NOT THE RETIRED HISTORY MARKERS.
--
-- `has_price_history` and `has_daily_history` came from `security.price_history_from` and
-- `security.daily_history_from`, which nothing has set since the edge price resources retired on
-- 2026-09-12. Both now read `market.security_price_span`, which the Dagster asset of that name
-- keeps (20261003160000).
--
-- The fixture makes the two rules DISAGREE, or deleting the re-point would pass:
--   * SPAN    holds a span and no old marker      -> present under the new rule only;
--   * MARKED  holds both old markers and no span  -> present under the old rule only;
--   * EMPTY   was reached by the lane and holds no bars (null dates) -> absent under both.
-- All three sit in a country of their own, so `coverage_current`'s per-bucket counts are the
-- fixture's and nothing else's.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZH','Historia','ZH',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000031601','T316 Span',  'equity','ZH'),
  ('00000000-0000-0000-0000-000000031602','T316 Marked','equity','ZH'),
  ('00000000-0000-0000-0000-000000031603','T316 Empty', 'equity','ZH')
on conflict (security_id) do nothing;

insert into market.security_price_span (security_id, first_date, last_date) values
  ('00000000-0000-0000-0000-000000031601', date '1999-01-04', current_date - 1),
  ('00000000-0000-0000-0000-000000031603', null, null)
on conflict (security_id) do nothing;

-- The old markers are dropped with the rest of the retired family (deferred, due 2026-10-12).
-- Set them while they exist, so the test keeps proving the old rule is gone and survives the drop.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'market' and table_name = 'security'
                and column_name = 'price_history_from') then
    execute $q$update market.security
                 set price_history_from = date '2006-01-02', daily_history_from = date '2006-01-02'
               where security_id = '00000000-0000-0000-0000-000000031602'$q$;
  end if;
end $$;

-- `security_facets` is MATERIALIZED: rebuilt after the fixture, non-concurrently so the test can
-- still roll back.
refresh materialized view market.security_facets;

do $$
declare
  span   constant uuid := '00000000-0000-0000-0000-000000031601';
  marked constant uuid := '00000000-0000-0000-0000-000000031602';
  empty  constant uuid := '00000000-0000-0000-0000-000000031603';
  got_price bigint; got_daily bigint; got_securities bigint;
begin
  -- 1. PER SECURITY.
  if (select count(*) from market.security_facet_status
       where security_id = span and facet in ('price_history','daily_history') and present) <> 2 then
    raise exception 'a security holding a span must read as having price and daily history';
  end if;
  if exists (select 1 from market.security_facet_status
              where security_id = marked and facet in ('price_history','daily_history') and present) then
    raise exception 'the retired history markers must no longer decide a facet';
  end if;
  if exists (select 1 from market.security_facet_status
              where security_id = empty and facet in ('price_history','daily_history') and present) then
    raise exception 'a span with null dates (the lane found no bars) must read as no history';
  end if;

  -- 2. PER BUCKET, from the universe view, which carries its own copy of the rule.
  select c.securities, c.with_price_history, c.with_daily_history
    into got_securities, got_price, got_daily
    from market.coverage_current c
   where c.dimension = 'country' and c.bucket = 'ZH' and c.security_type_code = 'equity';
  if got_securities is distinct from 3::bigint then
    raise exception 'the fixture country must hold the three fixture securities, got %', got_securities;
  end if;
  if got_price is distinct from 1::bigint or got_daily is distinct from 1::bigint then
    raise exception 'coverage_current must count exactly the security holding a span: price %, daily %',
      got_price, got_daily;
  end if;

  raise notice 'ok  the history facets read the price span (span present, old markers ignored, empty span absent)';
end $$;

rollback;
