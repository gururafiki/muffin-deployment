# muffin-deployment

Terraform + Ansible + Docker-Swarm deployment for the [Muffin](https://github.com/gururafiki/muffin)
agent on **Oracle Cloud Always-Free** (single ARM `A1.Flex`, single-node Swarm), behind **Traefik**
(Let's Encrypt via Cloudflare DNS-01) with **Cloudflare Access**. Only the chat UI + LangGraph API
are exposed; every MCP/infra service stays private on the overlay.

```
terraform/   OCI VM + VCN/subnet/security-list + Cloudflare DNS/Access  (+ ansible.tf: runs Ansible)
ansible/     muffin_stack.yml + roles/ (harden, swarm, deploy) + dynamic inventory (cloud.terraform)
stack/       the Swarm stack template (docker-compose.yaml, traefik.yml) + config.example.yml / secrets.example.yaml
compose/     local-dev docker-compose (langgraph dev) moved out of muffin-agent
config/      service configs (searxng, opensandbox, firecrawl)
```

Images come from the sibling repos: `muffin-agent`, `openbb-mcp-docker`, `agent-chat-ui-docker`,
`nuq-postgres-docker` (all `ghcr.io/gururafiki/*`).

**`openbb-mcp-docker` is deployed twice, as two services from ONE image.** `openbb-core`
hard-depends on fastapi/uvicorn, so the OpenBB Platform REST app ships in the same image as
the MCP server — `openbb-api` is just a different command against it:

| Service | Command | Port | Used by |
|---|---|---|---|
| `openbb-mcp` | `openbb-mcp` (image default) | 8001 | the agent's data-collection tools (MCP) |
| `openbb-api` | `uvicorn openbb_core.api.rest_api:app` | 6900 | the `market-refresh` edge function (plain REST) |

Neither is exposed through Traefik — both are overlay-internal and carry the provider API
keys. Browse the REST surface at `/docs` (278 routes) or `/openapi.json`. The route convention
is `obb.x.y.z` → `/api/v1/x/y/z`, but it is **not perfectly regular**: compare
`/api/v1/equity/price/performance` (slash) with `/api/v1/etf/price_performance` (underscore).
Check `/openapi.json` before adding a caller.

Provider notes worth not re-deriving: **finviz and yfinance need no API key**, and
`equity/compare/groups` (the sector/country/industry performance endpoint) is finviz-only and
**US-listed stocks only**. finviz's per-symbol `price_performance` is **broken upstream** — it
duplicates the first character of the symbol (`AAPL` → `'AAAPL' is not in list`, HTTP 422) — so
per-symbol performance must use **fmp**, which needs `FMP_API_KEY`.

## One-command deploy (single `terraform apply`)

Terraform provisions the infra **and** runs Ansible (no `generate_inventory.sh`): the
`ansible/ansible` provider declares `ansible_host` resources and the `cloud.terraform` inventory
plugin reads them from state, then a `terraform_data` provisioner runs `ansible-playbook`.

```bash
cd stack && cp config.example.yml config.yml && cp secrets.example.yaml secrets.yaml   # fill these in
cd ../terraform && cp muffin.tfvars.example terraform.tfvars                          # fill OCI + Cloudflare + key paths
pip install ansible-core && ansible-galaxy collection install cloud.terraform
terraform init && terraform apply        # VM + Cloudflare + Swarm + stack, one command
```

Then in Cloudflare set SSL/TLS → **Full (strict)**. `terraform output` exposes the public IP +
the Access service-token id/secret.

## CI deploy
`.github/workflows/deploy.yml` runs the same `terraform apply` on `workflow_dispatch`. It needs a
**remote Terraform state backend** (so runs share state) + the GitHub secrets listed in that file.

## Notes
- ARM64: all referenced images have arm64 builds (the `*-docker` repos publish arm64).
- Single node = no HA; back up the `langgraph-data` / `supabase-db-data` volumes (`pg_dump`).
- See `stack/docker-compose.yaml` for the full stack + memory budget.

## Data durability & the node-replacement hazard (read before deploying)

**All persistent data lives on a dedicated OCI Block Volume** mounted at `/mnt/data`, which
Docker's entire `data-root` points at. A block volume **survives instance replacement**; a boot
volume does not. That is the whole reason it exists — see "Disk layout" below.

The instance image comes from the `oci_core_images` data source, which resolves to the *newest*
matching Canonical Ubuntu image. Oracle rotates that image periodically, so a routine `terraform
apply` after a rotation used to see a changed `source_details.source_id`, mark it `# forces
replacement`, and destroy + recreate the node — losing all data. **This happened on 2026-07-20**
(Supabase accounts/backups + all LangGraph thread history lost; the terminated boot volume had
`preserve_boot_volume` off and no backups, so it was unrecoverable).

Guards now in `terraform/main.tf`:
- `lifecycle { ignore_changes = [source_details[0].source_id] }` — image drift no longer forces
  replacement; deploys are pure in-place stack updates. **A deliberate OS upgrade must back up the
  DBs first, then remove this ignore (or `terraform taint` the instance).**
- `preserve_boot_volume = true` — if the node is ever replaced anyway, its boot volume is kept for
  recovery instead of deleted.

**Automated backups: done** (nightly `pg_dumpall` of `supabase-db` → Object Storage — see below).
**Block volume: done** (2026-08-26) — a replacement can no longer lose the data in the first place,
rather than merely leaving it recoverable.

### Disk layout

`terraform/storage.tf` creates a 100 GB `oci_core_volume` (`prevent_destroy`, paravirtualized
attachment) and `ansible/roles/block_storage` formats it ext4, mounts it at `/mnt/data` **by UUID**
with `nofail`, and points Docker's `data-root` at `/mnt/data/docker`. Images, every named volume,
container layers and swarm state all live there together, so a replaced instance reattaches the
volume and finds everything already present — nothing to restore.

Three things here are load-bearing and easy to undo by accident:

- **`RequiresMountsFor=/mnt/data`** (a systemd drop-in on `docker.service`) is the most important
  line in the whole arrangement. `nofail` is correct for boot — a missing volume must not lock you
  out of SSH — but combined with `data-root` it is *precisely* what would let dockerd start on an
  **empty directory**: Postgres runs `initdb` and the entire stack comes up **green with blank
  databases**. `RequiresMountsFor` makes dockerd refuse to start instead. Down and loud beats up
  and lying.
- **`prevent_destroy` on the volume, and NOT on the attachment.** The attachment must stay
  replaceable or a genuine instance replacement deadlocks — which is the recovery this exists for.
- **The mount is by UUID, never `/dev/sdX`.** Device names are not stable across attachment order.

**`docker volume prune` is NOT safe on this node.** It removes any volume not referenced by a
*running or stopped* container, which includes anything whose service is temporarily at 0 replicas.
Use the name-filtered form, which can only ever touch anonymous volumes:

```bash
docker volume ls -qf dangling=true | grep -E '^[0-9a-f]{64}$' | xargs -r docker volume rm
```

Never add `--volumes` to the `docker system prune -af` in `muffin_stack.yml` — its "never volumes"
comment is load-bearing.

### Browsing files on the node

SFTP, over the SSH key you already have:

```bash
sftp -i ~/.ssh/oci_key ubuntu@<node-ip>
```

Any GUI client (Cyberduck, FileZilla, Finder) connects the same way. Note this required a fix: the
`ssh` role **replaces** `/etc/ssh/sshd_config` wholesale, and the distro's file is where the
`Subsystem sftp` line normally lives — so SFTP was silently disabled from the day the node was
built (`subsystem request failed on channel 0`), which is why `maintenance.yml` pipes scripts
through `ssh cat` instead of `scp`. The role now sets `Subsystem` explicitly. It adds no attack
surface: same key auth, and anyone who can SSH can already read any file.

**No file browser can tell you what is in the HTTP cache** — those are MD5-named blobs with a
binary header. See `docs/data-ingestion.md` §9c for the recipe that reads them, and why MinIO and
Supabase Storage both cannot.

## Database backups

A host cron takes a **nightly logical backup of `supabase-db`** (which holds Supabase auth + the app
tables + LangGraph's tables in `public`) and uploads it to OCI Object Storage.

- **What/where:** cluster **roles** (`pg_dumpall --roles-only`) + the **`postgres` database**
  (`pg_dump` — Supabase auth + storage metadata, the app tables, and LangGraph thread/run/store
  history) → gzip → `s3://muffin-db-backups/supabase-db/<UTC-timestamp>.sql.gz`. The LangGraph
  **`public.checkpoint*` tables are excluded from the dump DATA**; their schema is kept, so a
  restored DB has empty checkpoint tables that LangGraph repopulates. The dump is niced + `gzip -6`
  so it can't starve the single node.

  > ⚠ **This exclusion is a data-loss decision, not a free optimisation** (2026-07-27).
  > It was written when checkpoints were "the checkpointer's in-flight state, regenerable". They are
  > not regenerable and no longer redundant: muffin-ui reconstructs a past run's **execution tree**
  > — every sub-agent, transcript and tool call — from checkpoint history
  > (`muffin-ui/src/lib/agent/run-history.ts`), and the capture channels that used to duplicate that
  > into `thread.values` were deleted. **With checkpoints excluded, a restore yields threads with
  > their headline result but no record of how each run reached it.**
  >
  > The size figure that motivated the exclusion is also misleading. Measured on the node:
  > `checkpoint_blobs` was 1878 MB, but **1763 MB of it belonged to a single errored council thread**
  > (`019f8476-…`, 2026-07-21), and 95 % of all blob bytes are the `messages` channel — not the
  > capture channels (`subagent_runs` was 350 kB).

- **Turning it on.** Set `db_backups_include_checkpoints: true` in `config.yml`. Recommended order:

  1. `muffin-prune-thread.sh <thread-uuid>` on the node — **dry run**, prints what it would delete.
  2. Re-run with `--yes` for any pathological thread. Deleting `019f8476-…` takes the checkpoint
     tables to ~115 MB. **Irreversible: it destroys that run's history permanently.**
  3. Flip the flag and redeploy; confirm the next dump completes and check its size.

  `pg_dump` writes only live rows, so the dump shrinks the moment a thread is deleted — no `VACUUM`
  needed for that. The on-disk files stay their old size until autovacuum reuses the space, which is
  fine; `VACUUM FULL` takes an ACCESS EXCLUSIVE lock and needs free space equal to the table, so it
  is not worth running on this node just to reclaim disk.
- **Schedule/retention:** 03:00 UTC daily; the script prunes backups older than **30 days** (an OCI
  lifecycle policy would need a tenancy IAM grant to the Object Storage service principal, so we
  prune in-script instead). One backup also runs on every deploy.
- **How:** `ansible/muffin_stack.yml` renders `/usr/local/bin/muffin-db-backup.sh` + the cron and
  stages the S3 creds to `/etc/muffin/backup.env` (the **same** Customer Secret Keys as the tfstate
  backend — `AWS_ACCESS_KEY_ID`/`SECRET` from the deploy env; no new secret). Upload is a throwaway
  `amazon/aws-cli` container against the S3-compatible endpoint. Logs: `/var/log/muffin-db-backup.log`.
- **Scope:** `supabase-db` only. `langgraph-postgres` (unused since the cutover) and
  `firecrawl-postgres` (ephemeral crawl queue) are not backed up.

**Restore.** Two rules that make it actually work (verified 2026-07-21 — restoring as `postgres`
into the bare image silently drops `auth.users`):
1. Restore **as `supabase_admin`** — in the `supabase/postgres` image `postgres` is *not* a full
   superuser, so it can't restore the `auth`/`storage` objects.
2. The dump is taken with **`pg_dump --clean --if-exists`**, so it DROPs the image's pre-created stub
   objects (whose columns lag GoTrue's real schema) and recreates them from the backup.

```bash
# Pick a backup:
aws s3 ls s3://muffin-db-backups/supabase-db/ --endpoint-url $ENDPOINT
aws s3 cp s3://muffin-db-backups/supabase-db/<file>.sql.gz . --endpoint-url $ENDPOINT

# On the target node, restore into supabase-db (ideally freshly initialised — stop the app
# services first so nothing writes during the restore):
gunzip -c <file>.sql.gz | sudo docker exec -i "$(sudo docker ps -qf name=muffin_supabase-db|head -1)" \
  psql -U supabase_admin -d postgres -v ON_ERROR_STOP=0
# ON_ERROR_STOP=0 tolerates benign notices: "role already exists" / "reserved role, only superusers
# can modify it" (Supabase's roles are pre-created and protected) and "... does not exist, skipping"
# from the --clean DROP IF EXISTS. Then bring the stack up and verify:
#   auth.users (accounts), public.thread (LangGraph history), public.user_backups.
```

> **Test your backups.** Download the latest dump and restore it into a throwaway
> `docker run --rm -e POSTGRES_PASSWORD=x supabase/postgres:<tag>` (**as `supabase_admin`**), then
> assert `SELECT count(*) FROM auth.users` etc. match the source — an untested backup is not a backup.
> This exact test caught the `postgres`-vs-`supabase_admin` + stub-schema issues above.

## Supabase (self-hosted, M8)

The stack ships a self-hosted Supabase adapted from the official
[docker self-hosting guide](https://supabase.com/docs/guides/self-hosting/docker):
`supabase-db` (Postgres 17), `supabase-auth` (GoTrue), `supabase-rest` (PostgREST),
`supabase-realtime`, `supabase-storage` (+`supabase-imgproxy`), `supabase-functions`
(edge runtime), `supabase-kong` (public gateway at `https://<supabase_subdomain>.<domain>`),
`supabase-meta` + `supabase-studio` (admin, behind Cloudflare Access at
`https://<studio_subdomain>.<domain>`). Analytics/Logflare and the Supavisor pooler are
deliberately omitted (heavy; Postgres stays overlay-internal — nothing publishes 5432).
Deviations from upstream: legacy HS256 JWT keys (no asymmetric keypair — `auth.py` and
PostgREST verify the shared secret), Studio guarded by Access instead of Kong basic-auth.

**Setup**: run `stack/supabase/generate-keys.sh` once and paste its output into
`secrets.yaml` (locally) or the matching GitHub secrets (CI). App tables + RLS live in
`stack/supabase/migrations/` and are re-applied idempotently on every deploy.

**Order is explicit, not implicit.** `with_fileglob` returns filesystem order, not sorted
order — measured 2026-08-09, it ran the migrations `04, 01, 05, 02, 03`, so the ones needing
the `market` schema failed before `02` created it. The playbook now pipes the glob through
`| sort`; the numeric prefixes only mean anything because of that.

| Migration | What it does |
|---|---|
| `01-app.sql` | `user_backups`, `research_shares` (+ RLS) |
| `02-market.sql` | the **`market` schema**: sectors, `performance`, and the refresh claim (below) |
| `03-security.sql` | **revokes anon/authenticated access to everything else in `public`** (below) |
| `04-market-reference.sql` | classification schemes / groups / 667 memberships / 221 countries / regions — **generated** from muffin-ui's authored constants (see below) |
| `05-market-instruments.sql` | `market.instruments` — the per-sector ticker universe (35 seeded, `do nothing` so Studio edits stick) |
| `06-instrument-price-symbol.sql` | `price_symbol`, for names the provider knows by another ticker (NESN → `NESN.SW`) |
| `07-asset-universe.sql` | the non-equity universe (ETFs, commodities, crypto, bonds, funds, cash) + `priced` |
| `08-instrument-prices.sql` | `market.prices` — daily closes (~400-day window) behind the stock-page chart |
| `09-market-rls.sql` | **RLS on every `market` table** — public read policy, writes service-role only |

Refresh resources (`POST /functions/v1/market-refresh` with `{"resource": "..."}`):
`sector-performance` (30 min) · `country-performance` (60 min) · `instrument-performance`
(60 min) · `instrument-profile` (24 h — the only one that writes `market.instruments`
rather than `market.performance`, and the only one restricted to `asset_type = 'equity'`,
since an ETF or a coin has no sector to fetch).

Plus `instrument-prices` (24 h) — the daily closes the chart draws. It reuses the same batched
history the performance refresh already downloads, bounded to ~400 calendar days (~280 bars),
which is what 1M/3M/6M/1Y need; the 3Y/5Y *numbers* still come from `market.performance`.

**Forcing a refresh.** `begin_refresh` skips while data is inside its TTL, which is correct but
gets in the way when the data is fresh and *wrong*. Pass `force` — **service-role only**, since
the anon key is public and a public cache-buster is a free way to hammer the provider:

```bash
curl -X POST "https://supabase.<domain>/functions/v1/market-refresh" \
  -H "apikey: $SERVICE_ROLE" -H "Authorization: Bearer $SERVICE_ROLE" \
  -H "Content-Type: application/json" \
  -d '{"resource":"instrument-profile","force":true}'
```

`force` bypasses the TTL and the error backoff but **not** the in-flight lock — two concurrent
forced refreshes still collapse into one upstream fetch.

**Scheduled warm-up.** `.github/workflows/market-warmup.yml` nudges every resource at 02/08/14/20
UTC. Reads are stale-while-revalidate, so a visitor is never blocked — but without this the FIRST
visitor after a TTL expiry sees the previous values until the background fetch lands. Four runs a
day rather than one per TTL: the TTLs are 30–60 min, so a per-TTL schedule would be ~48 runs a day
against finviz and yfinance, and **yfinance rate-limits**. It uses the ANON key (the refresh
endpoint applies its own TTL guard, so a warm-up needs no elevated rights) and a `skipped` reply
counts as success — that is the warm-up finding data already fresh.

**`priced = false`** (cash, a bond yield) is excluded from the performance refresh on purpose:
a price return there is meaningless rather than missing, so the UI shows no number.

### The `market` schema (market data for muffin-ui)

`market.performance` holds every market figure the app renders, one row per
`(scope, scope_id, period)` — `scope` is `sector` / `country` / `instrument` / `group`, so new
data types add ROWS, not tables. Each row carries `as_of` + `stale_after`.

The app **reads it directly over PostgREST** (`supabase.schema('market')`) — there is no API
server in the path, which is why reads are fast and work before sign-in. Writes come only from
the **`market-refresh` edge function** (`stack/supabase/functions/market-refresh/`), which
fetches `openbb-api` and upserts. Requires `market` in `PGRST_DB_SCHEMAS` on **both**
`supabase-rest` and `supabase-studio`.

Freshness is **stale-while-revalidate**: a reader always gets what is in the table and never
waits on OpenBB; a stale row triggers a background refresh. Because the anon key is public,
`market.begin_refresh()` is an atomic claim that returns false if a refresh is in flight, if
one succeeded within the TTL, or if the last attempt failed and is still cooling off — so
concurrent triggers collapse into at most one upstream fetch.

`04-market-reference.sql` was **generated** from muffin-ui's authored constants rather than
transcribed. It carries two different conflict rules on purpose: schemes, groups and countries
upsert with `do update` (names, colours and ETF proxies are app presentation, so the app wins
on redeploy), while **memberships use `do nothing`** — which country sits in which group is
reference data meant to be corrected in Studio, and a redeploy must not revert an edit. To
force a reset, delete that scheme/lens's rows first.

`market.countries.etf_symbol` is the single-country ETF used as each country's equity-market
proxy; the refresh reads it from the table, so a corrected proxy takes effect with no redeploy.

Verify the provider mapping without deploying anything (needs only `openbb-api`):

```bash
docker compose -f compose/docker-compose.yml up -d openbb-api
docker run --rm --network host -v "$PWD:/w" -w /w -e OPENBB_API_URL=http://localhost:6900 \
  denoland/deno:alpine run --allow-net --allow-env \
  stack/supabase/functions/market-refresh/check.ts
```

### RLS on the `market` schema (`09-market-rls.sql`)

02–08 controlled access with **grants alone**. That is genuinely restrictive, but it leaves RLS
disabled — which Supabase's advisor flags as `rls_disabled_in_public`, and which is one stray
`grant` away from being wrong. Grants and policies now agree:

| Tables | RLS | Policy | Effect |
|---|---|---|---|
| reference + market data (9 tables) | on | `for select to public using (true)` | public read; **no** write policy, so writes are impossible even if a grant were added by mistake |
| `refresh_log` | on | **none** | RLS with zero policies denies every ordinary role; only `service_role` (BYPASSRLS) can touch the refresh mutex |

`service_role` bypasses RLS, so the `market-refresh` edge function is unaffected. Verified by
behaviour, not just flags: anon reads, anon writes are refused, `refresh_log` is invisible to
anon, and service_role can still read, write and call `begin_refresh`.

**LangGraph's tables in `public` are deliberately NOT given RLS**, even though the advisor flags
them too. They are already unreachable — `03-security.sql` revokes anon/authenticated and
re-applies every deploy. Enabling RLS there depends on langgraph-api's role having `BYPASSRLS`,
which has **not** been verified against the deployed `supabase/postgres` image; if it does not,
every agent run breaks. Silencing a warning on already-unreachable tables is not worth that.

### `03-security.sql` — the anon exposure on LangGraph's tables

Measured 2026-08-09: PostgREST publishes every `public` table the `anon` role can SELECT, and
Supabase grants that by default. Since LangGraph also keeps its tables in `public` (see the
cutover section), `GET /rest/v1/thread` and `/rest/v1/checkpoint_blobs` returned **real rows to
anyone holding the public anon key**. A sampled `checkpoints.metadata` row carried no
secret-shaped fields, so this was a content/privacy exposure rather than a credential leak.

The migration revokes `all` on everything in `public` from `anon`/`authenticated`, re-grants
only the app's own two tables, and — importantly — revokes the **default privileges** so
tables langgraph-api creates later do not re-acquire the grant. Being re-applied every deploy
is what makes it self-healing against LangGraph recreating its schema.

**On the legacy `anon` / `service_role` keys** (Studio shows a "deprecated" banner):
those are Supabase's new opaque **publishable** (`sb_publishable_…`) / **secret**
(`sb_secret_…`) API keys, which are independently revocable without rotating the JWT
secret. They are Cloud-oriented and, for self-hosting, need the asymmetric-key infra +
the Kong `SUPABASE_PUBLISHABLE_KEY`/`SUPABASE_SECRET_KEY` translation we deliberately
simplified out (see `kong-entrypoint.sh` upstream). The legacy HS256 `anon`/`service_role`
JWTs remain fully supported for self-hosting and are what `auth.py`, PostgREST and the app
verify against one shared secret — so we stay on them. Revisit only if independent key
rotation becomes a requirement (it would mean adopting the asymmetric keypair + the Kong
key-translation entrypoint).

### Auth e-mails (optional SMTP)

Without SMTP secrets, signups auto-confirm and password recovery is disabled. Set
`supabase_smtp_*` (secrets.yaml locally, or the `SUPABASE_SMTP_*` GitHub secrets in CI)
and GoTrue sends real confirmation/recovery e-mails (auto-confirm flips off automatically
when a host is present). Any SMTP provider works.

**Currently configured: Resend** (sending domain `rafiki.guru`) —
`host: smtp.resend.com`, `port: 587` (STARTTLS), `user: resend`, `pass: <resend-api-key>`,
`admin_email: no-reply@rafiki.guru`. Free tier: 3,000 e-mails/month, 100/day. The `from`
address must be on a Resend-verified domain.

Alternatives: **Cloudflare Email Service** (`smtp.mx.cloudflare.net:465`, `user: api_token`,
pass = a CF API token with Email Sending permission; free only to ≤200
[verified destination addresses](https://developers.cloudflare.com/email-service/configuration/email-routing-addresses/),
Workers Paid $5/mo for arbitrary recipients), Brevo, AWS SES, etc.

### OAuth providers (optional)

Email/password works out of the box. To add social sign-in, register an OAuth app on the
provider (callback URL **`https://<supabase_subdomain>.<domain>/auth/v1/callback`**, i.e.
`https://supabase.rafiki.guru/auth/v1/callback`) and set its client id + secret in
secrets.yaml / GitHub secrets. GoTrue enables the provider only when its id is present, and
the app auto-shows a "Continue with …" button (it reads `/auth/v1/settings`). Scaffolded
today: **GitHub** and **Google** (both free to use).

- **GitHub** (free): Settings → Developer settings → OAuth Apps → New OAuth App. Homepage
  `https://muffin.rafiki.guru`, callback as above. Set `supabase_github_client_id` /
  `supabase_github_secret` (GH secrets `SUPABASE_GITHUB_CLIENT_ID` / `SUPABASE_GITHUB_SECRET`).
- **Google** (free): Google Cloud Console → APIs & Services → Credentials → OAuth client ID
  (type: Web application). Authorised redirect URI = the callback above. Set
  `supabase_google_client_id` / `supabase_google_secret` (GH secrets
  `SUPABASE_GOOGLE_CLIENT_ID` / `SUPABASE_GOOGLE_SECRET`). Configure the OAuth consent screen.

Adding another GoTrue provider = a couple more `GOTRUE_EXTERNAL_<P>_*` lines on the
`supabase-auth` service + the matching secrets + a metadata entry in the app's
`src/features/account/oauth.ts`. See the roadmap for the full provider list + costs.

### LangGraph DB cutover (langgraph-postgres → supabase-db)

`use_supabase_db` (config.yml / `USE_SUPABASE_DB` repo variable) selects langgraph-api's
`DATABASE_URI`. When `true`, langgraph-api uses supabase-db's **`postgres`** database directly and
keeps its tables in **`public`** — so they're **browsable in Supabase Studio** (which is pinned to
that one database).

> **Why public, not a dedicated `langgraph` schema?** langgraph-api connects as `postgres` on the
> **default** search_path, does not honour a client-side `PGOPTIONS`, and **recreates its tables in
> `public` whenever they're missing**. Attempts to namespace it in a `langgraph` schema
> (`SET SCHEMA` + role-default search_path applied *after* the stack deploys) failed: langgraph-api
> raced ahead, recreated everything in public, and produced 500s + duplicate tables. A robust
> namespaced setup would require the schema + role search_path baked into a **supabase-db init
> script** (`/docker-entrypoint-initdb.d/`) so they exist *before* langgraph-api's first connection —
> not yet done. Until then, LangGraph lives in `public` alongside the app's `research_shares` /
> `user_backups` tables.

Runbook:

```bash
# 1. Deploy with use_supabase_db=false — Supabase comes up alongside the old DB.
# 2. On the node: dump the old langgraph DB and restore it into supabase-db's `postgres` (public).
ssh ubuntu@<node-ip>
OLD=$(sudo docker ps -qf name=muffin_langgraph-postgres | head -1)
NEW=$(sudo docker ps -qf name=muffin_supabase-db | head -1)
sudo docker service scale muffin_langgraph-api=0        # stop writers during the copy
sudo docker exec $OLD pg_dump -U postgres -Fc postgres > /tmp/langgraph.dump
sudo docker cp /tmp/langgraph.dump $NEW:/tmp/
sudo docker exec $NEW pg_restore -U postgres -d postgres --no-owner /tmp/langgraph.dump
# 3. Flip use_supabase_db=true and redeploy (terraform apply / deploy workflow).
# 4. Verify: langgraph-api healthy, old threads visible in the app's Calls tab + LangGraph's
#    tables visible in Supabase Studio (public schema of the postgres DB).
# 5. Rollback: flip back to false and redeploy (the old langgraph-postgres volume is untouched).
```

**Step 6 is now automatic.** `langgraph-postgres` is wrapped in
`{% if not use_supabase_db %}` in the stack template, so once the flag is true the service is
simply not rendered — freeing its 1 GB, which is what pays for the `openbb-api` service. Its
`langgraph-data` **volume is deliberately still declared**: the pre-cutover data stays on disk,
so flipping the flag back really is a rollback. Nothing here deletes it; that needs an explicit
`docker volume rm`.

Auth note: sign-in is **optional** (`MUFFIN_AUTH_OPTIONAL=true` on `langgraph-api`) —
anonymous requests share one `owner=anonymous` thread pool; signed-in users only see
their own threads. Threads created before M8 carry no `owner` metadata and are hidden
from everyone except the shared-token client; to hand them to the anonymous pool, run
once inside the langgraph database:

```sql
UPDATE thread SET metadata = metadata || '{"owner": "anonymous"}'::jsonb
WHERE NOT metadata ? 'owner';
```

## Market reference data (SEC N-PORT → the `market` schema)

The stock universe is built from **fund holdings**, not a screener. The tracked ETFs are
US-registered, so they file SEC **N-PORT** quarterly — public, keyless, and carrying
name/LEI/CUSIP/ISIN/country/weight per holding. Current state (2026-08-12): **60 funds → 10,060
securities, 17,474 holdings, 7,940 sector constituents**, replacing 35 hand-authored tickers.

### What identifies a security, and where it trades

Identity is a catalog, not runtime state: `security_identifier` is `PRIMARY KEY (kind, value)` and
holds 9,865 ISINs, 4,350 tickers and 1,495 CUSIPs, while the LEI lives on `issuer` because **an LEI
identifies the ISSUER, not the security** (GOOG and GOOGL share one).

Three tables added 2026-08-12 finish the picture:

| Table | What it is |
|---|---|
| `exchange` | The venue catalog — exchange code → country → the suffix the price provider uses. **The single source**; it previously existed both here and hardcoded in `exchanges.ts`, and the two had drifted to 54 rows against 38. |
| `listing` | Where a tracked security trades: `(security_id, exch_code)`, with `is_primary` naming the real quote. `exchange_listing` remains the raw OpenFIGI *directory* including companies no fund holds; this is the linked subset. |
| `security_price` | Daily closes for the whole universe, keyed on `security_id`. |

**A symbol is not a stable key.** The display symbol was `coalesce(ticker, provider_symbol)`, and
that ticker is OpenFIGI's *US* lookup — a thin OTC foreign-ordinary line for a foreign company. 41%
of non-US securities were labelled `SAABF`/`HXGBF` while being priced off `SAAB-B.ST`/`HEXA-B.ST`.
`listing.is_primary` now decides it per security, and re-keying what was already stored took a
hand-written migration. Anything keyed on `security_id` needed none, which is why `security_price`
is.

**`market.instruments` is a curated OVERLAY, not a duplicate universe.** Of its 47 rows, 8 are
editorial listing picks (`TSM`, `SAP`, `RIO` — the liquid ADR, where the fund-derived universe knows
only `TSMWF`, `SAPGF`) and 12 are not securities at all (`USD`, `US10Y`, `BTC`, `WTI`, `GLD`).
`priced = false` is what makes cash and a bond yield render **no number** rather than "+0.0%". It
carries a nullable `security_id`, and `instrument_current` merges the two: curated columns win for
editorial fields, the linked security supplies provider-refreshed ones.

### The refresh model — who calls what, and when

Every write to the `market` schema goes through ONE edge function, `market-refresh`, dispatched by
a `resource` name. Reads never go through it: the app reads the tables directly over PostgREST,
which is why a page renders instantly even while a refresh is in flight.

**Three things can trigger a refresh, and only one is automatic.**

| Trigger | Who | When | Credential |
|---|---|---|---|
| `market-warmup.yml` | GitHub Actions cron | every 3 hours, from 02:10 UTC | anon key |
| stale-while-revalidate | the app itself | a reader touches a row past `stale_after` | anon key |
| manual | you | on demand | anon, or service-role for `force` |

Every resource self-skips inside its TTL, so a warm-up pass costs almost nothing when the data is
fresh. `market-verify.yml` runs separately at 03:00 UTC and asserts the result as anon.

### The resources

| Resource | Writes | Upstream | TTL |
|---|---|---|---|
| `sector-performance` | `performance` (sectors) | finviz — **US-listed only** | 1 day |
| `country-performance` | `performance` (countries) | yfinance, per-country ETF | 1 day |
| `group-performance` | `performance` (tiers) | yfinance, per-group ETF | 1 day |
| `instrument-performance` | `performance` (35 curated) | yfinance | 1 day |
| `instrument-profile` | `instruments` sector/industry/cap | yfinance | 1 week |
| `instrument-prices` | `prices` (~400-day window) | yfinance, batched 12 | 1 day |
| `fund-holdings` | `security`, `issuer`, `fund_holding` | **SEC EDGAR** | 1 month |
| `derive-classifications` | `security_taxonomy`, country | none — a SQL join | 1 month |
| `security-tickers` | ticker identifiers | **OpenFIGI** | 1 day |
| `security-local-symbols` | `security_provider_symbol` (local lines) | **OpenFIGI** | 1 day |
| `security-yahoo-symbols` | `security_provider_symbol`, `listing` | **Yahoo search, by ISIN** | 1 day |
| `security-profiles` | `security_taxonomy` (sector) | yfinance | 1 day |
| `security-industries` | `taxonomy_node` level 2, `security.market_cap` | yfinance | 1 day |
| `security-performance` | `performance` (whole universe) | yfinance | 1 day |
| `security-prices` | `security_price` (~400-day daily window) | yfinance, **incremental** | 1 day |
| `security-fundamentals` | `security_fundamentals` | yfinance | 1 week |
| `security-statements` | `security_statement` | yfinance | 1 week |
| `exchange-listings` | `exchange_listing` (venue sweep) | **OpenFIGI** | 1 month |
| `security-refresh` | one security, on demand | yfinance | none |
| `promote-listing` | promotes an untracked listing | none | none |

**Every `security-*` resource is an INCREMENTAL BACKLOG**, not a full pass: it claims a page ordered
by fund weight, works until its ~55s deadline, and leaves the rest. Two rules they all share, both
learned the hard way:

- **A negative cache is mandatory.** Each has a `*_missing_at` column so a security the provider
  cannot answer for stops being re-asked for 30 days. Without one, unanswerable rows crowd out
  answerable ones forever — rediscovered four times, which is why there are four such columns.
- **A whole batch failing is an OUTAGE, not a batch of bad symbols.** If every symbol also fails
  alone, nothing is negative-cached. Draining aggressively once tripped a rate limit and marked
  1,369 perfectly good securities unanswerable for 30 days.

`security-prices` is incremental in a second sense: it fetches from the newest bar already stored
rather than a fixed window, so a daily refresh asks for one day (20 rows, ~1s) where a first pass
asks for four hundred (73,542 rows, ~52s).

**TTLs are pre-launch values — deliberately long.** Nobody is watching these numbers yet and every
refresh spends someone's free-tier quota. Tightening them at launch is tracked in `todos.md`.

### Making yourself an admin

Refresh is **admin-only** — any holder of the published anon key could otherwise spend the
deployment's provider quota. Admin is a Supabase-native claim: `app_metadata.role = 'admin'`.

**`app_metadata`, never `user_metadata`.** A signed-in user can write their own `user_metadata`
through the ordinary auth API, so a role kept there is self-assignable and worth nothing.
`app_metadata` is writable only with the service key or in Studio, and GoTrue copies it into every
token it issues — so it survives a refresh with no extra lookup.

Run this in Supabase Studio's SQL editor (`https://supabase-studio.<domain>`), against your own
account:

```sql
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
 where email = 'you@example.com';
```

Then **sign out and back in** in the app — the claim is baked into the access token when it is
issued, so an existing session keeps the old one until it refreshes.

To check it took:

```sql
select email, raw_app_meta_data->>'role' as role from auth.users where email = 'you@example.com';
```

To revoke: `set raw_app_meta_data = raw_app_meta_data - 'role'`.

Once the claim is live the app shows a **Refresh** control on each market page, and
`market-refresh` accepts your user token directly. Without it the endpoint answers **403** and the
control is not rendered at all.

### Running one by hand

```bash
# Any resource, via CI (uses the anon key; respects the TTL):
gh workflow run market-warmup.yml -f resource=fund-holdings

# Directly, with `force` to bypass the TTL — SERVICE-ROLE ONLY, because the anon key is public
# and a public cache-buster is a free way to hammer the provider:
curl -X POST "https://supabase.<domain>/functions/v1/market-refresh" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"resource":"fund-holdings","fund":"XLE","force":true}'
```

`force` clears the TTL and the error backoff but **not** the in-flight lock, so concurrent forced
refreshes still collapse into one upstream fetch.

### Adding an ETF (no deploy)

`market.tracked_fund` is the control surface and `market.ingest_run` is the log.

1. Insert a row in Studio: `symbol`, `name`, `kind` (`sector` / `country` / `group` / `other`),
   and `represents_code` — the `market.sectors` id for a sector fund, the ISO-2 for a country one.
   Leave it null and the fund contributes holdings but classifies nothing.
2. `{"resource":"fund-holdings","fund":"<SYMBOL>","force":true}` — seconds, not the monthly pass.
3. `{"resource":"derive-classifications","force":true}` — turns the new holdings into sector and
   country membership.
4. `{"resource":"security-tickers","force":true}` — resolves ISINs the new fund introduced.

To make a country drillable in the UI it also needs `market.countries.etf_symbol` set, which is
what `country-performance` reads.

Retire a fund with `enabled = false` — its holdings history is kept. `notes` is respected by the
migrations, so a hand edit is never reverted by a redeploy.

### What is missing, in one place

- **Sector classification is US-only** — it derives from the 11 US sector SPDRs, so a non-US
  security has no sector and a sector page filtered to a non-US country is empty.
- **Per-security % change covers only the 35 curated symbols**, so most constituents show no number.
- **Market cap and fundamentals are absent** — FMP's free tier gates them per SYMBOL.
- **`sector-performance` is finviz and US-listed only.** Do not present it as global, and do not
  present it on a country page as if it were that country's.
- **Only US-registered funds file N-PORT**, so non-US UCITS funds cannot be tracked at all.
- Full list, with what each would take: the umbrella `todos.md`.

### Things that will bite you

- **`<cusip>000000000</cusip>` is a placeholder, not a value**, and 72% of holdings carry it.
  Treating it as an identifier merges every one of them into a single security — silently.
- **An LEI names the issuer, not the security.** Resolution is ISIN → CUSIP → FIGI; the LEI
  populates `market.issuer`.
- **Find a filing with EDGAR full-text search**, not by walking a trust's submissions — a
  1,433-filing CIK buries a given fund deeper than any probe budget.
- **Fund weights do not sum to 100** (EWT's filing sums to 110.38). The `*_weight` views
  renormalise; anything else must too.
- **A PostgREST `in.()` filter is a URL** — 500 ISINs is 6.5 KB and the proxy returns a bare 502.
- **Ticker resolution is incremental** by design (OpenFIGI anonymous is 25 req/min × 10). Setting
  the free `OPENFIGI_API_KEY` raises it to 250 × 100 and clears the backlog in one pass.
- **Only US-registered funds file N-PORT**, so a non-US UCITS fund cannot be tracked at all.

## Observability (Grafana, Prometheus, Portainer)

Live at `https://muffin-grafana.<domain>` and `https://muffin-portainer.<domain>`, both behind
Cloudflare Access. Added 2026-08-27.

### Why it is split across two stores

The split is by the SHAPE of the data, not by tool preference:

| | Store | Retention | What |
|---|---|---|---|
| Slow, semantic, permanent | **Postgres** (`market.*`) | 400 days | backlog depth, per-run outcomes, universe coverage |
| Fast, high-cardinality, disposable | **Prometheus** | 15 days | container memory, request latency, cache hit ratio |
| Agent calls | **LangSmith + Langfuse** | (hosted) | every LLM call, token count and trace |

Grafana reads BOTH, so one dashboard shows backlog depth beside container memory. Because it has a
Postgres datasource, **the domain metrics need no exporter at all** — a panel is a `SELECT`.

**The load-bearing rule: Grafana reads SAMPLES, never the live `pending_*` views.** Counting all 26
costs ~8.4s (measured 2026-08-27; `pending_prices` alone is 5,380 ms, above the 8s statement
timeout the PostgREST role carries). A dashboard on a 30s refresh would run that continuously
against the database the app reads. `market.backlog_sample` is written 16 times a day and every
panel reads that. By contrast `count(*)` over every market TABLE is 771 ms for all 63, which is why
`sample_universe` needs none of this care.

### Where the data comes from

- **`market.refresh_run`** — one row per `market-refresh` invocation, written by a wrapper around
  the handler in `functions/market-refresh/index.ts`. Not at the ~40 `return json(...)` sites: a
  resource added below one of them would be silently unrecorded. `written`/`remaining`/`failed`
  are GENERATED from the report jsonb, so they cannot drift from it.
- **`market.backlog_sample` / `universe_sample`** — written by the `observability-sample` resource,
  which runs FIRST AND LAST in the warm-up sweep so each sweep is bracketed and you can see what
  it drained rather than inferring it.
- **`http-cache` `/metrics`** — Lua counters in `stack/proxy/nginx.conf`, exposed on the overlay
  only. `provider` is set explicitly per location, never derived from `$proxy_host` (two locations
  share `query2.finance.yahoo.com`).
- **Traefik, cAdvisor, node-exporter, postgres-exporter** — scraped by Prometheus.

**Known blind spot, stated rather than discovered later:** yfinance / finviz / FMP calls made
*inside* `openbb-api` do not traverse `http-cache`. The rate-limit signal that matters most
therefore comes from `refresh_run.error` and `report`, not from the cache counters.

### The four dashboards

| Dashboard | Answers |
|---|---|
| **Pipeline** | Is ingestion working? Backlog depth, run outcomes, rows written, recent failures |
| **Providers & cache** | Hit ratio, requests/s and p95 per provider, non-2xx by class |
| **Universe** | Securities/holdings/coverage over time, negative-cache populations, table sizes |
| **Node & services** | Per-container memory **as a share of its own limit**, CPU, disk, Traefik |

They are git-tracked JSON in `stack/observability/grafana/dashboards/` and provisioned from disk,
so a rebuilt Grafana comes back with all four. UI edits are allowed and are NOT written back —
anything worth keeping goes into the file.

### Alerts

Six rules, each modelled on a failure this pipeline has actually had. E-mail via the shared
`smtp_*` credentials (Resend). If `alert_email_to` is unset, Grafana still evaluates every rule and
shows firing alerts — it just cannot mail them.

| Alert | The failure it is modelled on |
|---|---|
| Resource has not succeeded in 12h | Four consecutive warm-up misses = broken, not a bad afternoon |
| **Backlog flat ≥24h while runs report ok** | **The stall signature — five occurrences.** `written: 7386` twice, byte-identical |
| Negative cache +20% in one interval | ~8,300 securities marked unanswerable in one afternoon (2026-08-13) |
| Container >85% of its own limit | openbb-api OOM-killed at 1 GB by one probe; supabase-kong measured 81% |
| Cache hit ratio collapsed | `inactive=` and an oversized key both break it SILENTLY |
| Filesystem >80% | `/` was at 70% on 2026-08-27 and grows with every image pull |

### Runbook — an alert fired

Each rule's `description` in Grafana is its runbook. In general:

```bash
# What did that resource actually report?
select started_at, ok, skipped, written, remaining, left(error, 200)
  from market.refresh_run where resource = '<name>' order by started_at desc limit 20;

# Is the backlog moving?
select sampled_at, depth from market.backlog_sample
 where backlog = 'pending_<x>' order by sampled_at desc limit 30;

# A bare 502 with no body means the WORKER died — memory, not error handling:
docker service logs muffin_supabase-functions --tail 200
```

For a negative-cache spike, read the `market-repair-negative-cache` skill **before** clearing
anything: a mark that was earned and a mark caused by a provider outage look identical in every
count, and clearing an earned one re-asks a rate-limited provider for an answer already held.

### Secrets it needs

`metrics_ro_password` (the read-only Postgres role Grafana and postgres-exporter use — **never
`service_role`**), `grafana_admin_password`, `alert_email_to`, and the shared `smtp_*` block. The
role is created NOLOGIN and passwordless by migration 127, because migrations are piped into `psql`
with no variable substitution; Ansible grants it LOGIN separately. Leave the password empty and the
role stays inert.

### Adding a metric

- A **domain** number: add it to `market.sample_universe()` — or add nothing at all, since every
  market table's row count and size is already discovered from `pg_tables`, and every
  `%_missing_at` column from `pg_attribute`.
- A **backlog**: nothing to do. `sample_backlogs()` discovers anything named `pending_%`.
- An **infra** number: a scrape target in `stack/observability/prometheus.yml`, or a line in
  `/usr/local/bin/muffin-cache-size.sh` for anything only the host can see.

## Remote state (OCI Object Storage)

Terraform state lives in the `muffin-tfstate` OCI Object Storage bucket via the S3-compatible backend
(`terraform/backend.tf`), so CI and local runs share one state. Auth is an **OCI Customer Secret Key**
(separate from the OCI API key), supplied as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. OCI rejects
AWS's chunked-upload encoding, so also export the checksum opt-outs. For **local** terraform:

```bash
export AWS_ACCESS_KEY_ID=<customer-secret-key-id>
export AWS_SECRET_ACCESS_KEY=<customer-secret-key-secret>
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
cd terraform && terraform init && terraform apply
```

In CI these come from the `TFSTATE_S3_ACCESS_KEY_ID` / `TFSTATE_S3_SECRET_ACCESS_KEY` GitHub secrets.
