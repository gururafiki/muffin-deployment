-- The filter spine must be MATERIALISED, CONCURRENTLY refreshable, and readable by anon.
--
-- WHY THIS IS A TEST. Measured on the deployed node 2026-08-19: as a plain view, filtering
-- `security_facets` by `msci_tier` AND `sector_id` took 2993ms and anon got
-- `57014 canceling statement due to statement timeout`, while service_role and every
-- single-predicate probe said the view was healthy. Each of the three properties below, if lost,
-- restores that failure or a worse one — and all of them are invisible to a functional test,
-- because a slow view returns the RIGHT ANSWER right up until it is killed.

\set ON_ERROR_STOP on

begin;

-- 1. IT IS A MATERIALIZED VIEW. Reverting it to a plain view reintroduces the timeout for every
--    two-filter combination, which is the normal case for this feature, not an edge case.
do $$
declare kind "char";
begin
  select c.relkind into kind
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'market' and c.relname = 'security_facets';
  if kind is null then raise exception 'market.security_facets does not exist'; end if;
  if kind <> 'm' then
    raise exception
      'security_facets is relkind % (expected m) — as a plain view, msci_tier AND sector_id took 2993ms against anon''s 3s statement timeout', kind;
  end if;
end $$;

-- 2. IT HAS A UNIQUE INDEX. Without one, `refresh materialized view concurrently` is rejected, the
--    refresh falls back to ACCESS EXCLUSIVE, and every read of the Markets tab blocks behind a
--    ~2s rebuild. The refresh would still "work", which is what makes this worth asserting.
do $$
declare n integer;
begin
  select count(*) into n
    from pg_index i join pg_class c on c.oid = i.indrelid
    join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'market' and c.relname = 'security_facets' and i.indisunique;
  if n = 0 then
    raise exception
      'security_facets has no UNIQUE index — `refresh materialized view concurrently` is rejected without one, so every refresh takes ACCESS EXCLUSIVE and blocks all readers';
  end if;
end $$;

-- 3. EVERY FILTER DIMENSION IS INDEXED. The point of materialising was BOUNDED cost for ANY
--    combination; an unindexed dimension is a sequential scan waiting for the one user who
--    filters by it.
do $$
declare col text; missing text[] := '{}';
begin
  foreach col in array array[
    'sector_id','industry','country_iso2','msci_tier','msci_region','ftse_tier',
    'income_group','wb_region','app_region_id','cap_band','style','security_type_code'
  ] loop
    if not exists (
      select 1
        from pg_index i
        join pg_class c    on c.oid = i.indrelid
        join pg_namespace ns on ns.oid = c.relnamespace
        join pg_attribute a on a.attrelid = c.oid and a.attnum = any(i.indkey)
       where ns.nspname = 'market' and c.relname = 'security_facets' and a.attname = col
    ) then
      missing := missing || col;
    end if;
  end loop;
  if array_length(missing, 1) > 0 then
    raise exception 'filter dimensions with no index: % — each one is a seq scan for whoever filters by it', missing;
  end if;
end $$;

-- 4. ANON CAN READ IT and CANNOT REFRESH IT. The app reads with the anon key; the refresh rebuilds
--    27,629 rows and is a free way to load the database for anyone holding the public anon key.
do $$
begin
  if not has_table_privilege('anon', 'market.security_facets', 'select') then
    raise exception 'anon cannot read security_facets — the app reads with the anon key';
  end if;
  if has_function_privilege('anon', 'market.refresh_facets()', 'execute') then
    raise exception
      'anon can execute refresh_facets() — it rebuilds 27,629 rows, and the anon key is public. A SECURITY DEFINER function keeps the default PUBLIC execute grant unless it is explicitly revoked';
  end if;
  if not has_function_privilege('service_role', 'market.refresh_facets()', 'execute') then
    raise exception 'service_role cannot refresh the spine, so it would never be rebuilt';
  end if;
end $$;

-- 5. THE SNAPSHOT CARRIES ITS AGE. A spine that silently stops refreshing is the failure mode this
--    codebase keeps hitting; `refreshed_at` is what lets the app and market-verify see it.
do $$
declare has_col boolean;
begin
  -- pg_attribute, NOT information_schema.columns: matviews are not in the SQL standard and
  -- information_schema OMITS THEM ENTIRELY, so the catalogue view reports zero columns for this
  -- relation and any check written against it fails for a reason that has nothing to do with the
  -- column. (Measured while writing this test — it reported refreshed_at missing when it is
  -- plainly there.)
  select exists (
    select 1 from pg_attribute a
      join pg_class c     on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'market' and c.relname = 'security_facets'
       and a.attname = 'refreshed_at' and a.attnum > 0 and not a.attisdropped
  ) into has_col;
  if not has_col then
    raise exception 'security_facets has no refreshed_at — the snapshot''s age must be a fact the app can read, not something to infer';
  end if;
end $$;

rollback;
