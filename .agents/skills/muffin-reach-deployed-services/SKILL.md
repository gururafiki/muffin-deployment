---
name: muffin-reach-deployed-services
description:
  Use when reading or querying the deployed muffin stack from a terminal or browser — the node, its
  Postgres databases, Dagster, Grafana, Portainer, the LangGraph API or Supabase — or when a
  muffin hostname answers with a Cloudflare Access login, 302, 401 or 403.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Reach the deployed services

Every host below except `supabase` is behind Cloudflare Access. **Do not route around Access; go
through one of the three doors.** Never write a credential into a file, skill, memory, commit or
command output. Name where it lives, ask the user for it, and read it into a variable.

| `*.rafiki.guru` | What | Guard |
|---|---|---|
| `muffin` | Expo app | Access |
| `muffin-chat` | legacy chat UI | Access |
| `muffin-api` | LangGraph API, reference at `/docs` | Access |
| `supabase-studio` | Supabase Studio | Access |
| `muffin-grafana` | Grafana | Access, then Grafana login |
| `muffin-portainer` | Portainer (holds the Docker socket) | Access, then Portainer login |
| `muffin-dagster` | Dagster UI (can launch runs) | Access |
| `supabase` | Supabase gateway: PostgREST, GoTrue, functions | public; anon key + JWT + RLS |

Measured 2026-09-17: each Access host answers an unauthenticated request with `302` to
`muffin-dev.cloudflareaccess.com/cdn-cgi/access/login/…`.

## The three doors

1. **SSH onto the node** (no Access hop): `ssh muffin` (`~/.ssh/config`, user `ubuntu`). Prefer it for
   databases, Dagster and logs.
2. **Access service token, for API calls only.** Send `CF-Access-Client-Id` and
   `CF-Access-Client-Secret` headers. It opens every Access host (200 from `muffin-dagster/server_info`,
   `muffin-grafana/api/health` and `muffin-portainer/api/system/status` on 2026-09-17). It is a
   Terraform output (`cloudflare_access_service_token_client_id`/`_client_secret`) and not a GitHub
   secret: ask the user. Set a `User-Agent`, because Cloudflare 403s urllib's default one.
3. **SSO in a browser**, for an email in `cloudflare_access_emails`. A browser cannot send the token
   headers, and moving a `CF_Authorization` cookie into one is credential injection. For Playwright,
   sign in once in its persistent profile.

## On the node

**Postgres** (`supabase-db`: database `postgres` holds `market`/`ingest`; `dagster` is run storage):

```bash
ssh muffin 'docker exec $(docker ps -qf name=muffin_supabase-db) psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -c "set statement_timeout = 30000" -c "select …" </dev/null'
```

- **Direction of stdin.** Use `</dev/null` when the SQL is in `-c`, and `docker exec -i … < file.sql`
  when it arrives on stdin. Each mistake fails silently.
- `psql -c` does not interpolate `:'var'`; pipe the statement in instead.
- **Always set `statement_timeout`.** Killing ssh leaves the query running, and one once blocked a
  deploy for 22 minutes. Stop one with `pg_terminate_backend(pid)` and `pid <> pg_backend_pid()`.
- `postgres` is not a superuser here; `supabase_admin` is. To see what a role can read, connect as
  `psql -U supabase_admin` and run `set role metrics_ro;` or `set role anon;`.
- Filter big tables by date (`price_bar` is ~58M rows); an unfiltered count times out.

**Dagster GraphQL**, from inside the webserver container (no Access, no token):

```bash
ssh muffin 'docker exec -i $(docker ps -qf name=muffin_dagster-webserver) python - <args>' < script.py
```

The script posts to `http://127.0.0.1:3000/graphql`. Location `muffin_ingest`, repository
`__repository__`. Ready-made scripts are in `muffin-dagster-operations`.

**Logs:** `docker service logs muffin_<service> --since 30m` (list services with `docker service ls`).
Each `http-cache` line starts with the cache status (`HIT`, `MISS`, `STALE`…).

**Traps:**
- `pgrep -f <path>` over ssh matches its own shell, so a stopped process reads as running.
- `sudo cmd /dir/*` globs as `ubuntu`; use `sudo bash -c '…'`.
- Never fix the node by hand (`muffin-deploy`).

## Grafana

- **API:** the service token plus Grafana basic auth. The working admin password is the one Grafana
  stored at first start, which is **not** the value in its container environment (different sha256,
  measured 2026-09-17). Ask the user for it.
- **Without it:** replay the panel's SQL on the node as `metrics_ro` (`muffin-grafana-dashboards`).

## LangGraph API and Supabase

The umbrella README § *Calling the deployed API* has the recipe: service-token headers for reads, and
a Supabase *user* token from the GoTrue password grant on `supabase.rafiki.guru` for runs. 403 means
no credential was sent; 401 means a credential was sent and failed. PostgREST reads take the anon key
(`apikey` and `Authorization: Bearer`) plus `Accept-Profile: market`.
