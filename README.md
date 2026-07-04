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

### Auth e-mails (optional SMTP)

Without SMTP secrets, signups auto-confirm and password recovery is disabled. To enable
real e-mails set `supabase_smtp_*` in secrets.yaml — e.g. **Cloudflare Email Service**:
onboard the domain (`npx wrangler email sending enable <domain>`), create an API token
with Email Sending permission, then `host: smtp.mx.cloudflare.net`, `port: 465`,
`user: api_token`, `pass: <cf-api-token>`. Arbitrary recipients need Workers Paid
($5/mo, 3k mails/mo included); on the free plan you may only send to up to 200
[verified destination addresses](https://developers.cloudflare.com/email-service/configuration/email-routing-addresses/)
— which matches the Access-allowlist posture. Resend/Brevo free tiers work the same way.

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
