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
- Single node = no HA; back up the `langgraph-data` volume (`pg_dump`).
- See `stack/docker-compose.yaml` for the full 14-service stack + memory budget.

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
