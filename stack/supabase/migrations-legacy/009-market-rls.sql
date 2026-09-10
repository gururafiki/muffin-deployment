-- Row-level security on the `market` schema — IDEMPOTENT.
--
-- 02/04/05/07/08 controlled access with GRANTS alone: select to anon+authenticated,
-- writes to service_role. That is genuinely restrictive, but it leaves RLS disabled,
-- which Supabase's advisor flags (`rls_disabled_in_public`) and which is one missing
-- `grant` away from being wrong. Grants and policies should agree, and both should
-- say the same thing out loud.
--
-- The model, unchanged in effect:
--   * reference + market data — PUBLIC READ. These are market facts, identical for
--     every user, and the globe has to render before sign-in. The policy says
--     `using (true)` for select and there is no insert/update/delete policy, so
--     writes are impossible for anon/authenticated even if a grant were added by
--     mistake later.
--   * refresh_log — RLS ON WITH NO POLICY AT ALL. That denies everything to every
--     ordinary role; only service_role (BYPASSRLS) can see or touch it. It holds no
--     user data, but it is the refresh mutex and nothing outside the edge function
--     has any business reading it.
--
-- service_role bypasses RLS, so the market-refresh edge function is unaffected.
--
-- NOT DONE HERE: RLS on LangGraph's tables in `public` (thread, checkpoints,
-- checkpoint_blobs, run, store). Supabase's advisor flags those too, but they are
-- already unreachable — 03-security.sql revokes anon/authenticated and re-applies
-- every deploy. Enabling RLS there would depend on langgraph-api's role having
-- BYPASSRLS, which I have NOT verified against the deployed supabase/postgres
-- image; if it does not, every agent run breaks. Silencing an advisor warning on
-- already-unreachable tables is not worth that risk. See the README.

do $$
declare t text;
begin
  foreach t in array array[
    'sectors', 'performance', 'countries', 'regions', 'instruments', 'prices',
    'classification_schemes', 'classification_groups', 'classification_members'
  ] loop
    execute format('alter table market.%I enable row level security', t);
    -- `to public` covers anon and authenticated (and anyone added later); the GRANT
    -- is still what decides whether a role can reach the table at all.
    execute format($p$
      do $inner$ begin
        create policy %I on market.%I for select to public using (true);
      exception when duplicate_object then null; end $inner$;
    $p$, t || '_public_read', t);
  end loop;
end $$;

-- Deliberately no policy: RLS with zero policies denies all non-bypassing roles.
alter table market.refresh_log enable row level security;

notify pgrst, 'reload schema';
