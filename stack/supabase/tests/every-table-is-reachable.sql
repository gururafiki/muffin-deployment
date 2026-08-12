-- Can the roles that use these tables actually reach them?
--
-- WHY. The migration tests apply DDL as a superuser, so they prove a table can be CREATED and say
-- nothing about whether anyone can READ or WRITE it. Two failures today were exactly that shape,
-- both invisible until production:
--
--   [Error] security_price upsert failed: permission denied for table security_price
--   -- migration 42 granted the two views and forgot the table they read
--
--   PGRST205 -- 15 tables 404'd over the API after two successful deploys, because PostgREST had
--   not rebuilt its schema cache (see the umbrella CLAUDE.md)
--
-- A new table works locally, applies cleanly twice, passes every existing check, and is unreachable
-- in production. `has_table_privilege` is checked rather than `set role`, so this needs no
-- transaction juggling and reports every offender instead of dying on the first.

\set ON_ERROR_STOP on

do $$
declare
  t          text;
  missing    text[] := '{}';
  -- `refresh_log` is written ONLY through `begin_refresh`/`finish_refresh`, which are
  -- `security definer`, and it deliberately carries RLS with NO policy so every non-bypassing role
  -- is denied. It is the one table service_role is not expected to reach directly.
  exempt     text[] := array['refresh_log'];
begin
  for t in
    select tablename from pg_tables where schemaname = 'market' order by tablename
  loop
    if t = any(exempt) then continue; end if;

    if not has_table_privilege('service_role', format('market.%I', t), 'SELECT') then
      missing := missing || format('%s (SELECT)', t);
    end if;
    -- service_role is the INGEST role. A market table it cannot write is either an oversight — the
    -- `security_price` case — or a deliberate read-only reference table, and there are none of
    -- those here: even the lookup tables are learned from filings at runtime.
    if not has_table_privilege('service_role', format('market.%I', t), 'INSERT') then
      missing := missing || format('%s (INSERT)', t);
    end if;
  end loop;

  if array_length(missing, 1) > 0 then
    raise exception E'service_role cannot reach % market table(s): %\n'
      'The resource that writes them will fail with "permission denied for table ..." in production '
      'while every migration test passes.',
      array_length(missing, 1), array_to_string(missing, ', ');
  end if;

  raise notice '  ok  service_role can read and write every market table';
end $$;

-- The public read path: anon is what the app uses, and a serving view nobody can select is the
-- same defect one layer up. Checked for VIEWS specifically, because that is what the UI reads.
do $$
declare
  v       text;
  missing text[] := '{}';
  -- Internal by design, and checked against what actually reads them:
  --   `pending_*`        the ingest's work queue, granted to service_role only.
  --   `untracked_listing` an operator surface behind the admin-gated promote flow.
  --   `fund_holding_current` a BUILDING BLOCK, used only inside other views. A view resolves its
  --     underlying objects as its OWNER, so `sector_constituents` reads it fine while anon cannot —
  --     which is the correct shape, not a missing grant.
  internal text[] := array['untracked_listing', 'fund_holding_current'];
begin
  for v in
    select viewname from pg_views
     where schemaname = 'market' and viewname not like 'pending_%' and viewname <> all(internal)
     order by viewname
  loop
    if not has_table_privilege('anon', format('market.%I', v), 'SELECT') then
      missing := missing || v;
    end if;
  end loop;

  if array_length(missing, 1) > 0 then
    raise exception E'anon cannot read % serving view(s): %\n'
      'The app reads these; a missing grant is a blank page, not an error.',
      array_length(missing, 1), array_to_string(missing, ', ');
  end if;

  raise notice '  ok  anon can read every serving view';
end $$;
