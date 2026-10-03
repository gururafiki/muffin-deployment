-- `market.directory_query` must list every question the venue directory asks, once.
--
-- The Dagster sensor seeds one `exchange_sweep` partition per row, so the view IS the partition grid
-- and each mistake below becomes walks nobody wanted or questions nobody asks:
--
--   1. every enabled venue x every enabled type, plus the enabled aliases, and no key twice
--      (a duplicate key is two questions sharing one partition, and one cursor);
--   2. `US.arca` asks NYSE Arca and files under US, flagged for the composite mapping, while
--      `US.common` asks US itself;
--   3. a disabled venue asks nothing, including an alias filed under it;
--   4. a disabled type is asked of no venue, including through an alias;
--   5. the worker can read its questions and cannot write them.
--
-- The fixture brings its own venues: no migration seeds `market.exchange`, so CI's database has none
-- and the migration therefore skips the `US.arca` seed, which the fixture supplies.

\set ON_ERROR_STOP on

begin;

insert into market.exchange (exch_code, country_iso2, suffix, enabled) values
  ('US', 'US', '',    true),
  ('LN', 'GB', '.L',  true),
  ('ZZ', 'US', '.ZZ', false)
on conflict (exch_code) do update set enabled = excluded.enabled;

insert into market.directory_alias (query_key, exch_code_asked, files_under, security_type2, reason) values
  ('US.arca', 'UP', 'US', 'Common Stock', 'fixture'),
  ('ZZ.local', 'ZL', 'ZZ', 'Common Stock', 'fixture: an alias filed under a disabled venue')
on conflict (query_key) do nothing;

do $$
declare
  v_venues  integer;
  v_types   integer;
  v_aliases integer;
  v_rows    integer;
  v_keys    integer;
begin
  select count(*) into v_venues from market.exchange where enabled;
  select count(*) into v_types from market.directory_type where enabled;
  select count(*) into v_aliases
    from market.directory_alias a
    join market.exchange e on e.exch_code = a.files_under and e.enabled
    join market.directory_type t on t.security_type2 = a.security_type2 and t.enabled
   where a.enabled;
  select count(*), count(distinct query_key) into v_rows, v_keys from market.directory_query;

  if v_types < 4 then
    raise exception 'expected the four seeded types, found % enabled', v_types;
  end if;
  if v_rows <> v_venues * v_types + v_aliases then
    raise exception 'directory_query has % rows, expected % venues x % types + % aliases',
      v_rows, v_venues, v_types, v_aliases;
  end if;
  if v_keys <> v_rows then
    raise exception 'directory_query repeats a key: % rows, % distinct keys', v_rows, v_keys;
  end if;
end $$;

-- 2. The two US common-stock questions differ in what they ask, not where they file.
do $$
begin
  if not exists (select 1 from market.directory_query
                  where query_key = 'US.arca' and exch_code_asked = 'UP' and files_under = 'US'
                    and security_type2 = 'Common Stock' and maps_to_composite) then
    raise exception 'US.arca must ask UP, file under US, and map each line to its composite';
  end if;
  if not exists (select 1 from market.directory_query
                  where query_key = 'US.common' and exch_code_asked = 'US' and files_under = 'US'
                    and not maps_to_composite) then
    raise exception 'US.common must ask US itself, with no composite mapping';
  end if;
  if exists (select 1 from market.directory_query where query_key !~ '^[A-Z0-9]+\.[a-z]+$') then
    raise exception 'a query_key is not of the shape VENUE.type';
  end if;
end $$;

-- 3. A disabled venue asks nothing: neither its own questions nor an alias filed under it.
do $$
begin
  if exists (select 1 from market.directory_query where files_under = 'ZZ') then
    raise exception 'a disabled venue is still asked: %',
      (select string_agg(query_key, ', ') from market.directory_query where files_under = 'ZZ');
  end if;
end $$;

-- 4. A disabled type is asked of no venue, through an alias included.
update market.directory_type set enabled = false where security_type2 = 'Common Stock';
do $$
begin
  if exists (select 1 from market.directory_query where security_type2 = 'Common Stock') then
    raise exception 'a disabled type is still asked: %',
      (select string_agg(query_key, ', ') from market.directory_query
        where security_type2 = 'Common Stock');
  end if;
  if not exists (select 1 from market.directory_query where query_key = 'US.reit') then
    raise exception 'disabling one type must not take the others with it';
  end if;
end $$;

-- 5. `ingest_rw` reads the list and cannot edit it. The default privilege that would otherwise grant
-- it DML exists only in a database built from the legacy migrations, which is what CI builds.
do $$
declare
  t text;
  p text;
begin
  foreach t in array array['market.directory_type', 'market.directory_alias'] loop
    if not has_table_privilege('ingest_rw', t, 'SELECT') then
      raise exception 'ingest_rw cannot read %', t;
    end if;
    foreach p in array array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] loop
      if has_table_privilege('ingest_rw', t, p) then
        raise exception 'ingest_rw holds % on %: the worker could rewrite its own questions', p, t;
      end if;
    end loop;
  end loop;
  if not has_table_privilege('ingest_rw', 'market.directory_query', 'SELECT') then
    raise exception 'ingest_rw cannot read market.directory_query';
  end if;
end $$;

rollback;
