---
name: muffin-deploy
description:
  Use when shipping a change to the deployed muffin stack — merging a PR in muffin-ingest,
  muffin-deployment, muffin-ui, muffin-agent or a docker repo, rolling the ingest image, running the
  Oracle deploy, or checking that what merged is what is running.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Ship a change to production

**Deployable repos ship only through a PR: open it → checks green → merge.** The umbrella (docs,
skills, submodule re-pins) pushes directly. Never repair the node by hand; fix the repo and ship
again, or the next deploy proves nothing.

## 1. Merge only on green, and check what "green" means

```bash
gh pr create -R gururafiki/<repo> --base main --head <branch> --title "…" --body-file -
gh pr view <n> -R gururafiki/<repo> --json statusCheckRollup,mergeStateStatus \
  --jq '{merge: .mergeStateStatus, checks: [.statusCheckRollup[] | {name: (.name // .context), status, conclusion}]}'
gh pr merge <n> -R gururafiki/<repo> --squash --delete-branch
```

- **Compare the check set with a known-good PR on the same repo.** muffin-ingest shows `checks`,
  `definitions` and `image` SUCCESS (`image` has built on every PR since 2026-09-19 and pushes only
  from `main`), plus CodeQL's three. A PR with merge conflicts runs no `pull_request` workflow at
  all, so it reads green with fewer checks.
- `gh pr merge` merges whatever the checks said, and a watcher's exit code is not their verdict.
  Read the rollup first.
- A squash merge orphans the umbrella's pin, so re-pin the submodule and push the umbrella.
- **A stacked PR is CLOSED, not retargeted, when its parent merges with `--delete-branch`.**
  Measured 2026-10-04: merging muffin-ingest#92 deleted the base of #93, and GitHub closed #93
  instead of moving it to `main`. Retarget the child first (`gh pr edit <child> --base main`). If it
  has already closed, reopening needs the base branch restored AND the head the PR closed with; a
  force-push while it was closed makes `gh pr reopen` fail with "Could not open the pull request".
- `muffin-ingest` joined Tier 1 on 2026-09-19: ruleset 23699949 requires `checks`, `definitions`
  and `image`.

## 2. Pick the path

| Change | Path | Measured |
|---|---|---|
| muffin-ingest code | `quality.yml` on `main` builds the arm64 image → `maintenance.yml` `roll-ingest` | build + image ~1.5 min, roll ~1.5 min (2026-09-16/17) |
| schema, compose, nginx, `dagster.yaml`, Grafana provisioning, Ansible, Terraform | `deploy.yml` | 9–11 min (2026-09-12/13) |
| muffin-ui, muffin-agent, docker-wrapper images | their image build dispatches `deploy` | muffin-ui image ~11 min (2026-09-13) |

### When not to ship (UTC)

| Window | What runs |
|---|---|
| 00:00–02:15 | the price night: `nightly_prices`, `daily_fx`, `daily_indices`. A roll kills their runs. |
| 03:00 | the symbology lane's daily stale-miss tick (`new_symbols_needed`), which launches runs |
| 03:30–~06:00 | the company lane (`yahoo_companies`, since 2026-10-18) holds the `yfinance` and `sql` pools; the derived runs created meanwhile wait until it ends (05:51 on its first day) |
| while `muffin-db-backup.sh` runs | every deploy ends with a full `pg_dump`, and anon reads time out while it runs: measure latency only after `pgrep -fc '[m]uffin-db-backup.sh'` reads 0 |

A deploy no longer restarts the Dagster services (the roll pins the digest, #431 and #436), so
only a roll kills runs. A deploy inside a window still competes with the runs for the database.

### Roll the ingest image

```bash
SHA=$(gh api repos/gururafiki/muffin-ingest/commits/main --jq .sha)
RUN=$(gh run list -R gururafiki/muffin-ingest --workflow quality.yml --branch main \
      --json databaseId,headSha --jq ".[] | select(.headSha==\"$SHA\") | .databaseId" | head -1)
gh run watch -R gururafiki/muffin-ingest "$RUN" --interval 30 --exit-status   # THIS sha's image
gh workflow run -R gururafiki/muffin-deployment maintenance.yml --ref main -f action=roll-ingest
```

- Select the build by `headSha`: for ~20 s after a merge, the newest run is still the previous
  commit's.
- **Poll `gh run view <id> --json status` rather than piping `gh run watch` into `--log`.** On
  2026-09-24 that pipeline was still waiting ten minutes after a roll that had finished in ninety
  seconds; which half hung was not established. The polling loop returned as soon as the run did.
- **Only the roll moves the ingest image** (Phase 4 decision 19, since muffin-deployment#431). The
  roll pins `<tag>@sha256:<the digest it pulled>` into all three specs, and the deploy renders the
  string the code location's spec holds, so a deploy finds nothing to change and does not restart
  Dagster. Until a pinned roll has run, the specs still hold the bare `:latest` an older roll left,
  and the next deploy restarts all three services: that is how a running backfill lost 303 runs on
  2026-10-03. Check a restart on the task (`docker service ps`, then `docker inspect <task>`), never
  on the service's `UpdatedAt`, which moves on every deploy. To make a deploy move ingest, change
  `image_ingest`; it keeps a pinned digest only while that digest belongs to the configured tag.
  See `docs/deferred/2026-09-26-a-deploy-rolls-the-ingest-image.md`.
- **A roll kills in-flight runs.** Each run is a `multiprocessing` child of the code server
  (`dagster/_grpc/server.py`, `StartRun`). The roll warns (`::warning::N run(s) in flight`), goes
  ahead, and since muffin-deployment#387 reports the runs it killed as failed once the new location
  has loaded (`== interrupted runs ==`). Wait for long runs anyway (`muffin-dagster-operations`) —
  a failed run is still lost work. If the roll exits early it prints `::error::interrupted and still
  holding their pool slots: <ids>`, and those must be failed by hand.
- **Read the roll's log.** A good roll prints `pulled <tag>`, `pinning <tag>@sha256:…`,
  `gRPC SERVING`, `muffin_ingest: LOADED`, then `== images ==` with `<service> <old> -> <new>` for
  all three services, `== specs ==` with `pinned` for all three, and `== interrupted runs ==` when
  something was in flight. `unchanged` is right only if nothing new was pushed. It fails loudly on
  `pull … failed`, `cannot read the digest`, `never reported SERVING`, `did not load`,
  `cannot say what is running` and `a deploy would replace the services left unpinned`.
- It logs free disk before pulling. If `/` is low, run `-f action=prune-images` first; that job fails
  below 5 GB free.
- Dagster upgrade: compare `dagster/_core/storage/alembic/versions` between the two versions. New
  revisions need `dagster instance migrate` before the roll.

### Deploy

```bash
gh workflow run -R gururafiki/muffin-deployment deploy.yml --ref main -f mode=plan    # diff only
gh workflow run -R gururafiki/muffin-deployment deploy.yml --ref main -f mode=apply
gh run watch -R gururafiki/muffin-deployment <run-id> --interval 30 --exit-status
```

- **A Terraform change to the instance: plan on the BRANCH before merging**
  (`--ref <branch> -f mode=plan`), then read the instance's own line in the log, not only the
  replacement list, e.g. `# oci_core_instance.node[0] will be updated in-place` and
  `boot_volume_size_in_gbs = "47" -> "95"`. That is how the 2026-09-25 boot-volume grow was cleared
  before merge.
- **An Ansible change: run `ansible-playbook --syntax-check ansible/muffin_stack.yml` locally
  first.** The repo's offline guards do not parse the playbook. On 2026-09-25 an apostrophe in a
  bash comment inside a `shell:` body failed CI's syntax check: Ansible splits the body with its own
  argument splitter, which reads the apostrophe as an unbalanced quote.
- `mode=plan` fails when anything would be REPLACED, because replacing the instance destroys every
  database.
- Deploys queue, never cancel (`concurrency: deploy-oracle`). A Galaxy 504 on the runner is
  transient: dispatch again.
- **A deploy that fails while Terraform refreshes state has applied nothing.** `401` with
  Cloudflare code `10000` on every Cloudflare resource means the `CLOUDFLARE_API_TOKEN` secret
  stopped authenticating (2026-09-21, 2026-10-06). Replacing it is the user's credential action.
  The token is account-owned (`cfat_`), so check it at `/accounts/{account_id}/tokens/verify`:
  `/user/tokens/verify` answers 401 for a valid one. Rolls go over SSH and are unaffected.
- **A change to how the database is built** (the baseline, `before-migrations.sql`, a migration
  that schedules pg_cron): CI's `postgres:17-alpine` cannot show what breaks, because `postgres` is
  a superuser there and pg_cron is absent. Prove it on production's own image in a throwaway
  container on the node: `supabase/postgres:<tag>` started with
  `-c config_file=/etc/postgresql/postgresql.conf` (which preloads pg_cron), and the pinned
  Supabase CLI in `debian:12-slim` with `--network container:<db>`, against `127.0.0.1`. The CLI
  leaves a root-owned `.temp`, so clean up with `sudo`.
- Every deploy restarts Grafana; a dashboard left open across it shows "No Data" until refreshed.

## 3. Verify what is running

- **Ingest:** after the roll, the next `heartbeat` (hourly at :07) must be SUCCESS, and so must
  the next scheduled run of anything you changed. **Read its counters**
  (`muffin-dagster-operations`). A LOADED location is not a working lane: every run failed for four
  days behind one, and the first night after the fix succeeded while publishing half a price day.
- **Schema:** on the node,
  `select version, name from supabase_migrations.schema_migrations order by version desc limit 3`,
  then read the changed view as `anon` (`muffin-reach-deployed-services`).
- **UI:** grep the served bundle for a string the change introduced. The public host is behind
  Access, so read the files in the running container from the node:
  `docker exec $(docker ps -qf name=muffin_muffin-ui) grep -rl '<string>' /usr/share/nginx/html`,
  and check the container's `StartedAt` is after the deploy.
