#!/usr/bin/env bash
# Roll the three Dagster services onto the newest build of the image their spec already names.
#
# WHY THIS EXISTS. `muffin-ingest`'s `quality.yml` already builds and pushes an arm64 image on every
# push to main (`:latest` and `:<sha>`), and every service that runs it renders `:latest`. What was
# missing is the step that tells the node to pull it — so an asset change either waited for an
# unrelated deploy or was applied by hand. This is that step, in the repo, reviewed, and reachable
# only through the same trusted path as every other node action.
#
# It is deliberately NOT a deploy: no terraform, no ansible, no migrations re-applied, no config
# restaged. If a change touches `dagster.yaml`, the workspace, the compose file or the schema, this
# script is the wrong tool and a deploy is the right one.
#
# THE ONE DETAIL THAT MAKES OR BREAKS IT: the running spec carries the tag AND the digest Swarm
# resolved at deploy time —
#
#     ghcr.io/gururafiki/muffin-ingest:latest@sha256:31720d44042bb0...
#
# Passing that back to `docker service update --image` re-pins the OLD digest, so the command
# succeeds, the tasks restart, and the node keeps running exactly the image it was already running.
# A silent no-op that reads as a successful roll. The digest is therefore stripped, and the before
# and after digests are printed so the roll can be seen to have done something.
set -euo pipefail

SERVICES=(muffin_muffin-ingest muffin_dagster-daemon muffin_dagster-webserver)
CODE_LOCATION_HOST=muffin-ingest
CODE_LOCATION_PORT=4000

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# A roll restarts the code location, and a run executes as a subprocess OF the code location — so
# anything in flight dies with it. Report rather than refuse: the count is what tells you whether to
# care, and blocking on it would make the roll unusable exactly when a bad build needs replacing.
inflight() {
  docker exec "$(docker ps -qf name=muffin_supabase-db | head -1)" \
    psql -U postgres -d dagster -tAc \
    "select count(*) from runs where status in ('STARTED','STARTING','CANCELING')" </dev/null 2>/dev/null || echo "?"
}

running="$(inflight)"
if [ "$running" != "0" ] && [ "$running" != "?" ]; then
  echo "::warning::${running} run(s) in flight; rolling the code location interrupts them"
fi

declare -A BEFORE
for svc in "${SERVICES[@]}"; do
  ref="$(docker service inspect "$svc" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')"
  BEFORE["$svc"]="${ref##*@}"
  tag="${ref%%@*}"
  log "rolling $svc  (tag $tag, was ${BEFORE[$svc]})"
  # --force so the tasks are recreated even when the digest is unchanged; --image with the digest
  # STRIPPED so the tag is re-resolved against the registry.
  docker service update --quiet --force --image "$tag" "$svc" >/dev/null
done

log "waiting for the code location to serve"
# NOT a replica count. Every one of these services reported 1/1 at some point while crash-looping
# during Phase 1, which is why the check drives the thing rather than watching it.
deadline=$((SECONDS + 180))
until docker exec "$(docker ps -qf name=muffin_dagster-daemon | head -1)" \
        dagster api grpc-health-check -h "$CODE_LOCATION_HOST" -p "$CODE_LOCATION_PORT" </dev/null >/dev/null 2>&1; do
  [ "$SECONDS" -lt "$deadline" ] || { echo "::error::gRPC server never reported SERVING"; exit 1; }
  sleep 5
done
log "gRPC SERVING"

# SERVING IS NOT LOADED. `dagster api grpc` answers the health check while its definitions are in
# error — that separation is the whole point of running the code location out of process, so the UI
# can report a broken build instead of disappearing with it. The only honest question is what the
# webserver says the location's load status is.
log "asking the webserver whether the definitions loaded"
deadline=$((SECONDS + 180))
while :; do
  if docker exec -i "$(docker ps -qf name=muffin_dagster-webserver | head -1)" python - <<'PY'
import json, sys, urllib.request

Q = """{ workspaceOrError { __typename
      ... on Workspace { locationEntries { name loadStatus
          locationOrLoadError { __typename ... on PythonError { message } } } }
      ... on PythonError { message } } }"""
req = urllib.request.Request(
    # 127.0.0.1, never localhost: the container resolves localhost to ::1 as well, and the server
    # binds IPv4 only, so the probe gets "connection refused" against a healthy process.
    "http://127.0.0.1:3000/graphql",
    data=json.dumps({"query": Q}).encode(),
    headers={"Content-Type": "application/json"},
)
body = json.load(urllib.request.urlopen(req, timeout=30))
ws = body["data"]["workspaceOrError"]
if ws["__typename"] != "Workspace":
    print("workspace error:", ws.get("message", ws)); sys.exit(1)

bad = 0
for e in ws["locationEntries"]:
    err = e["locationOrLoadError"] or {}
    if e["loadStatus"] != "LOADED" or err.get("__typename") == "PythonError":
        bad += 1
        print(f"{e['name']}: {e['loadStatus']} {err.get('message', '')[:800]}")
    else:
        print(f"{e['name']}: LOADED")
sys.exit(1 if bad else 0)
PY
  then
    break
  fi
  [ "$SECONDS" -lt "$deadline" ] || { echo "::error::code location did not load"; exit 1; }
  sleep 10
done

echo
echo "== digests =="
for svc in "${SERVICES[@]}"; do
  after="$(docker service inspect "$svc" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')"
  after="${after##*@}"
  if [ "$after" = "${BEFORE[$svc]}" ]; then
    printf '%-28s unchanged %s\n' "$svc" "$after"
  else
    printf '%-28s %s -> %s\n' "$svc" "${BEFORE[$svc]}" "$after"
  fi
done
