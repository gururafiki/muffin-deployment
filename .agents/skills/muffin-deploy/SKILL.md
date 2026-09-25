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
- `muffin-ingest` joined Tier 1 on 2026-09-19: ruleset 23699949 requires `checks`, `definitions`
  and `image`.

## 2. Pick the path

| Change | Path | Measured |
|---|---|---|
| muffin-ingest code | `quality.yml` on `main` builds the arm64 image → `maintenance.yml` `roll-ingest` | build + image ~1.5 min, roll ~1.5 min (2026-09-16/17) |
| schema, compose, nginx, `dagster.yaml`, Grafana provisioning, Ansible, Terraform | `deploy.yml` | 9–11 min (2026-09-12/13) |
| muffin-ui, muffin-agent, docker-wrapper images | their image build dispatches `deploy` | muffin-ui image ~11 min (2026-09-13) |

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
- **A roll kills in-flight runs.** Each run is a `multiprocessing` child of the code server
  (`dagster/_grpc/server.py`, `StartRun`). The roll warns (`::warning::N run(s) in flight`), goes
  ahead, and since muffin-deployment#387 reports the runs it killed as failed once the new location
  has loaded (`== interrupted runs ==`). Wait for long runs anyway (`muffin-dagster-operations`) —
  a failed run is still lost work. If the roll exits early it prints `::error::interrupted and still
  holding their pool slots: <ids>`, and those must be failed by hand.
- **Read the roll's log.** A good roll prints `pulled <tag>`, `gRPC SERVING`, `muffin_ingest: LOADED`,
  then `== images ==` with `<service> <old> -> <new>` for all three services, and
  `== interrupted runs ==` when something was in flight. `unchanged` is right only if nothing new
  was pushed. It fails loudly on `pull … failed`, `never reported SERVING`, `did not load` and
  `cannot say what is running`.
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
- Every deploy restarts Grafana; a dashboard left open across it shows "No Data" until refreshed.

## 3. Verify what is running

- **Ingest:** after the roll, the next `ledger_heartbeat` (hourly at :07) must be SUCCESS, and so must
  the next scheduled run of anything you changed. **Read its counters**
  (`muffin-dagster-operations`). A LOADED location is not a working lane: every run failed for four
  days behind one, and the first night after the fix succeeded while publishing half a price day.
- **Schema:** on the node,
  `select version, name from supabase_migrations.schema_migrations order by version desc limit 3`,
  then read the changed view as `anon` (`muffin-reach-deployed-services`).
- **UI:** fetch the served bundle and grep for a string the change introduced.
