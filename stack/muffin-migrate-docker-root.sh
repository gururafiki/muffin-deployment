#!/usr/bin/env bash
# Move Docker's data-root onto the persistent block volume. RUN ONCE, BY HAND.
#
# WHY THIS IS NOT AN ANSIBLE TASK. The playbook re-runs on every `terraform apply`
# (`replayable = true`). Copying ~30 GB with dockerd stopped is a once-ever operation, and putting
# it inside a play that runs on every deploy is how it eventually runs at the wrong moment. Kept
# here, `terraform apply` NEVER stops dockerd. A replaced node does not need this script at all —
# roles/block_storage runs before roles/docker, so a fresh node is configured correctly from its
# first start and the volume already holds everything.
#
# WHAT MAKES THIS SAFE: it never touches /var/lib/docker. The old store is left completely intact
# and is reclaimed later by a separate, human-triggered action. That deferral IS the rollback —
# if anything at all goes wrong, revert daemon.json and start docker on the old root.
#
# WHAT THIS DOES *NOT* MOVE, measured on the node 2026-08-26. Docker here uses the CONTAINERD
# SNAPSHOTTER (`Storage Driver: overlayfs`, `driver-type: io.containerd.snapshotter.v1`), not
# docker-ce's own overlay2 graph driver — so image layers live in /var/lib/containerd (16G
# snapshotter + 4.6G content = 21G), which `data-root` does not touch. This script therefore
# relocates the ~7.6G of VOLUMES plus swarm state, and images stay on the boot volume.
#
# That is the right trade for now: volumes are irreplaceable, images are re-pullable, and the
# growth risk (http-cache) is a volume. Moving containerd's root as well is a follow-up — it needs
# `root =` in /etc/containerd/config.toml and its own migration.
#
# The `rootfs` directory inside data-root looks like 16G to `du` but is NOT separate data — it is
# the overlay MOUNTS of containerd's layers. rsync correctly does not copy it.
#
# TWO RSYNC FLAGS ARE MANDATORY, NOT TIDINESS:
#   -H  overlay2 hardlinks layers together. Without it the store balloons and can exceed the
#       target, and image layers silently stop being shared.
#   -X  overlay2 stores `trusted.overlay.*` xattrs. Without them you get an image store that looks
#       fine and fails much later, in a way that is very hard to trace back to here.
#   `cp -a` preserves NEITHER of these. Do not substitute it.
set -euo pipefail

MOUNT="${DATA_MOUNT_POINT:-/mnt/data}"
NEW_ROOT="$MOUNT/docker"
OLD_ROOT="/var/lib/docker"
MARKER="$NEW_ROOT/.migrated"
DAEMON_JSON="/etc/docker/daemon.json"

log() { echo "$(date -u +%FT%TZ) migrate-docker-root: $*"; }
die() { log "ABORT: $*"; exit 1; }

# ---- preconditions -----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
mountpoint -q "$MOUNT" || die "$MOUNT is not a mountpoint — the block volume is not mounted"
[ -f "$MOUNT/.muffin-data-volume" ] || die "sentinel missing — $MOUNT is not the muffin data volume"
[ -f "$MARKER" ] && { log "already migrated (marker present) — nothing to do"; exit 0; }

need=$(du -sb "$OLD_ROOT" | cut -f1)
have=$(df -B1 --output=avail "$MOUNT" | tail -1)
required=$(( need * 115 / 100 ))
log "old root $(numfmt --to=iec "$need"), target free $(numfmt --to=iec "$have"), need $(numfmt --to=iec "$required")"
[ "$have" -ge "$required" ] || die "not enough free space on $MOUNT"

# ---- baseline ----------------------------------------------------------------------------------
# NAMED volumes only. Anonymous ones (64-hex) are created BY containers as they start, so
# immediately after `systemctl start docker` — before Swarm has recreated anything — the count is
# legitimately lower. Comparing totals there compares a settled number against an unsettled one and
# reverts a perfectly good migration. Measured: baseline 10 (6 named + 4 anon), post-start 6
# (6 named + 0 anon), settled again 9. The named volumes are the invariant that matters.
named_before=$(docker volume ls -q | grep -vE '^[0-9a-f]{64}$' | wc -l)
imgs_before=$(docker image ls -q | wc -l)
root_before=$(docker info --format '{{.DockerRootDir}}')
log "baseline: $named_before named volumes, $imgs_before images, root=$root_before"
[ "$root_before" = "$OLD_ROOT" ] || die "docker root is already $root_before, not $OLD_ROOT"

# ---- warm pass: dockerd STILL RUNNING, zero downtime -------------------------------------------
# Copies ~99% of the data with the stack fully up. Exit 24 ("vanished files") is expected and fine
# here precisely because the daemon is live.
log "warm pass (dockerd running)…"
mkdir -p "$NEW_ROOT"
set +e
rsync -aHAX --numeric-ids "$OLD_ROOT/" "$NEW_ROOT/"
rc=$?
set -e
[ $rc -eq 0 ] || [ $rc -eq 24 ] || die "warm rsync failed with $rc"
log "warm pass done (rc=$rc)"

# ---- cold pass: the only downtime, seconds --------------------------------------------------
# Stop the SOCKET first. Stopping only the service lets systemd socket activation restart dockerd
# underneath the rsync — a classic and total foot-gun.
log "stopping docker (socket first)…"
systemctl stop docker.socket || true
systemctl stop docker
sleep 2

log "cold pass (delta only)…"
rsync -aHAX --numeric-ids --delete "$OLD_ROOT/" "$NEW_ROOT/" || {
    log "cold rsync FAILED — daemon.json untouched, marker not written"
    systemctl start docker
    die "rolled back to $OLD_ROOT; nothing was lost"
}

# ---- switch ------------------------------------------------------------------------------------
# Byte-identical to what roles/docker renders, so the next deploy is a no-op and nothing flaps.
cp -a "$DAEMON_JSON" "${DAEMON_JSON}.pre-blockvol"
cat > "$DAEMON_JSON" <<JSON
{
  "data-root": "$NEW_ROOT",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON

log "starting docker on the new root…"
systemctl start docker
for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done

# ---- verify, and revert on ANY disagreement ----------------------------------------------------
root_after=$(docker info --format '{{.DockerRootDir}}')
named_after=$(docker volume ls -q | grep -vE '^[0-9a-f]{64}$' | wc -l)
imgs_after=$(docker image ls -q | wc -l)
log "after: $named_after named volumes, $imgs_after images, root=$root_after"

revert() {
    log "VERIFICATION FAILED: $1 — reverting to $OLD_ROOT"
    systemctl stop docker.socket || true
    systemctl stop docker
    mv "${DAEMON_JSON}.pre-blockvol" "$DAEMON_JSON"
    systemctl start docker
    die "reverted; $OLD_ROOT is untouched and the stack is on it"
}
[ "$root_after" = "$NEW_ROOT" ]      || revert "root is $root_after"
[ "$named_after" -ge "$named_before" ] || revert "named volumes $named_after < $named_before"
[ "$imgs_after" -ge "$imgs_before" ] || revert "images $imgs_after < $imgs_before"

touch "$MARKER"
rm -f "${DAEMON_JSON}.pre-blockvol"
log "MIGRATED. $OLD_ROOT is deliberately left intact — reclaim it separately, after a soak."
df -h / "$MOUNT" | sed 's/^/  /'
