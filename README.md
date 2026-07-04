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

## One-command deploy (single `terraform apply`)

Terraform provisions the infra **and** runs Ansible (no `generate_inventory.sh`): the
`ansible/ansible` provider declares `ansible_host` resources and the `cloud.terraform` inventory
plugin reads them from state, then a `terraform_data` provisioner runs `ansible-playbook`.

```bash
cd stack && cp config.example.yml config.yml && cp secrets.example.yaml secrets.yaml   # fill these in
cd ../config && cp ../../muffin-agent/extras/opensandbox/config.toml opensandbox/   # if not already present
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

### LangGraph DB cutover (langgraph-postgres → supabase-db)

`use_supabase_db` (config.yml / `USE_SUPABASE_DB` repo variable) selects langgraph-api's
`DATABASE_URI`. Runbook:

```bash
# 1. Deploy with use_supabase_db=false — Supabase comes up alongside the old DB.
# 2. On the node: dump the old DB and restore it into supabase-db's `langgraph` database.
ssh ubuntu@<node-ip>
OLD=$(sudo docker ps -qf name=muffin_langgraph-postgres | head -1)
NEW=$(sudo docker ps -qf name=muffin_supabase-db | head -1)
sudo docker service scale muffin_langgraph-api=0        # stop writers during the copy
sudo docker exec $OLD pg_dump -U postgres -Fc postgres > /tmp/langgraph.dump
sudo docker cp /tmp/langgraph.dump $NEW:/tmp/
sudo docker exec $NEW pg_restore -U postgres -d langgraph --no-owner /tmp/langgraph.dump
# 3. Flip use_supabase_db=true and redeploy (terraform apply / deploy workflow).
# 4. Verify: langgraph-api healthy, old threads visible in the app's Calls tab.
# 5. Rollback: flip back to false and redeploy (the old volume is untouched).
# 6. Once verified for a few days: remove the langgraph-postgres service + volume.
```

Auth note: sign-in is **optional** (`MUFFIN_AUTH_OPTIONAL=true` on `langgraph-api`) —
anonymous requests share one `owner=anonymous` thread pool; signed-in users only see
their own threads. Threads created before M8 carry no `owner` metadata and are hidden
from everyone except the shared-token client; to hand them to the anonymous pool, run
once inside the langgraph database:

```sql
UPDATE thread SET metadata = metadata || '{"owner": "anonymous"}'::jsonb
WHERE NOT metadata ? 'owner';
```

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
