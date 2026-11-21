-- `market.refresh_facets()` records its duration and row count in `universe_sample`, so a refresh
-- that stops is visible ("An observability sample has stopped arriving"), and refuses a refresh that
-- would serve an empty spine, rolling it back (migration 20261121140000).

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.security (security_id, name, security_type_code)
values ('00000000-0000-0000-0000-00000000f5c1', 'F5C1 Spine', 'equity')
on conflict (security_id) do nothing;

do $$
declare
  n bigint;
  rows_sampled double precision;
  ms double precision;
begin
  select rows_refreshed into n from market.refresh_facets();
  select value into rows_sampled from market.universe_sample
   where metric = 'facets.rows' order by sampled_at desc limit 1;
  select value into ms from market.universe_sample
   where metric = 'facets.duration_ms' order by sampled_at desc limit 1;
  if n is null or n < 1 then
    raise exception 'refresh_facets must return the spine''s row count, got %', n;
  end if;
  if rows_sampled is distinct from n::double precision then
    raise exception 'refresh_facets must record facets.rows = % in universe_sample, got %', n, rows_sampled;
  end if;
  if ms is null or ms < 0 then
    raise exception 'refresh_facets must record facets.duration_ms, got %', ms;
  end if;
  if (select count(distinct sampled_at) from market.universe_sample
       where metric in ('facets.rows', 'facets.duration_ms')
         and sampled_at = (select max(sampled_at) from market.universe_sample where metric = 'facets.rows')) <> 1
     or (select count(*) from market.universe_sample
          where metric in ('facets.rows', 'facets.duration_ms')
            and sampled_at = (select max(sampled_at) from market.universe_sample where metric = 'facets.rows')) <> 2 then
    raise exception 'one refresh must be filed as one sample: both rows under one timestamp';
  end if;
  raise notice 'ok  a refresh records its row count and duration under one timestamp';
end $$;

-- An empty universe is refused, and the refresh is rolled back with it.
savepoint empty;
truncate market.security cascade;
do $$
begin
  begin
    perform market.refresh_facets();
  exception when others then
    if sqlerrm like '%empty universe%' then
      raise notice 'ok  an empty spine is refused';
      return;
    end if;
    raise;
  end;
  raise exception 'refresh_facets must refuse a refresh that would serve an empty universe';
end $$;
rollback to savepoint empty;

rollback;
