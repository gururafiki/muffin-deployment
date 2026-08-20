-- Muffin app tables in the Supabase `postgres` database — IDEMPOTENT (re-applied on
-- every deploy by muffin_stack.yml AFTER GoTrue has run its own migrations, because
-- these tables reference auth.users / auth.uid()).
--
-- Access model: clients hit these through PostgREST with the user's Supabase JWT;
-- RLS below is the entire authorisation layer.

-- === Cloud backup (opt-in): one row per user, owner-only =====================
create table if not exists public.user_backups (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  -- Wealth-store snapshot (portfolio, accounts, goals) — client-shaped JSON.
  wealth     jsonb,
  -- NON-SECRET settings subset only; the client strips *_api_key / tokens before upload.
  settings   jsonb,
  updated_at timestamptz not null default now()
);

alter table public.user_backups enable row level security;

do $$ begin
  create policy user_backups_owner on public.user_backups
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
exception when duplicate_object then null; end $$;

-- === Shared research library =================================================
create table if not exists public.research_shares (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users (id) on delete cascade,
  title      text not null,
  query      text not null,
  -- The research graph's ResearchOutput (answer_markdown, key_findings, sources, …).
  output     jsonb not null,
  is_public  boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.research_shares enable row level security;

do $$ begin
  create policy research_shares_owner on public.research_shares
    for all using (auth.uid() = owner) with check (auth.uid() = owner);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy research_shares_public_read on public.research_shares
    for select using (is_public);
exception when duplicate_object then null; end $$;

create index if not exists research_shares_created_idx
  on public.research_shares (created_at desc) where is_public;

-- PostgREST discovers tables through the anon/authenticated roles' grants.
grant select on public.research_shares to anon, authenticated;
grant insert, update, delete on public.research_shares to authenticated;
grant all on public.user_backups to authenticated;

-- Reload PostgREST's schema cache so new tables are visible without a restart.
notify pgrst, 'reload schema';
