-- Close the anon read exposure on LangGraph's tables — IDEMPOTENT, re-applied on
-- every deploy (which is what makes it self-healing; see below).
--
-- THE PROBLEM (measured 2026-08-09 against the live deployment)
--   PostgREST publishes every table in `public` that the `anon` role can SELECT, and
--   Supabase's bootstrap grants `anon` SELECT on public tables by default. After the
--   M8 cutover LangGraph keeps ITS tables in `public` too (deliberately — see
--   muffin_stack.yml: a dedicated schema was tried and abandoned because
--   langgraph-api recreates its tables in public whenever they are missing).
--
--   So LangGraph's tables inherited the anon grant and had no RLS. With the anon key
--   — which is served publicly in muffin-ui's runtime-config.js — this returned real
--   rows:
--       GET /rest/v1/thread?select=thread_id,metadata   -> 200, owner UUIDs + graph_id
--       GET /rest/v1/checkpoint_blobs                   -> 200
--   i.e. any user's run content was readable by anyone. (A sampled
--   `checkpoints.metadata` row carried no secret-shaped fields, so this is a content
--   and privacy exposure rather than a credential leak.)
--
-- WHY REVOKE RATHER THAN ENABLE RLS
--   RLS on LangGraph's tables would be dropped the moment langgraph-api recreates
--   one, and it owns that schema. Revoking is re-applied every deploy, so it heals
--   itself; the default-privileges change below then stops NEW LangGraph tables from
--   ever being exposed in the first place.
--
-- WHY A BLANKET REVOKE RATHER THAN A TABLE LIST
--   Naming LangGraph's tables (thread, run, assistant, checkpoints, checkpoint_blobs,
--   checkpoint_writes, store, cron, …) would silently miss whatever it adds in the
--   next release. Revoke everything in `public` from the two PostgREST roles, then
--   re-grant exactly the app's own tables — the list that must stay in sync is
--   OURS, and it is right here next to the revoke.

-- === 1. Nothing in `public` is reachable by the PostgREST roles by default ====
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- === 2. Future tables do not re-acquire it ===================================
-- Supabase's bootstrap does `alter default privileges for role postgres in schema
-- public grant all on tables to postgres, anon, authenticated, service_role`, so the
-- revoke must name the same role to match that entry. langgraph-api connects as
-- `postgres`, so this is the one that covers the tables it recreates.
alter default privileges for role postgres in schema public
  revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;

do $$ begin
  execute 'alter default privileges for role supabase_admin in schema public
             revoke all on tables from anon, authenticated';
exception when others then null;  -- role absent on a plain-postgres deployment
end $$;

-- === 3. Re-grant the app's own tables ========================================
-- Mirrors the grants at the end of 01-app.sql. RLS on these two is what actually
-- scopes rows to their owner; the grants only decide which tables PostgREST shows.
grant select                    on public.research_shares to anon, authenticated;
grant insert, update, delete    on public.research_shares to authenticated;
grant all                       on public.user_backups    to authenticated;

-- service_role is the trusted server-side identity (edge functions). It keeps full
-- access — it is never handed to a browser.
grant all on all tables    in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- Reload PostgREST's schema cache so the removed tables stop being advertised.
notify pgrst, 'reload schema';
