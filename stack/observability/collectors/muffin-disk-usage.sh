#!/bin/sh
# Per-directory disk usage for node-exporter's textfile collector.
#
# WHY THIS REPLACES muffin-cache-size.sh, which was wrong in two ways at once:
#
#   1. IT READ A HARDCODED /var/lib/docker PATH. Docker's data-root on this node is
#      /mnt/data/docker, and /var/lib/docker is the STALE pre-migration copy — 7.6 GB of it is
#      still sitting there. So `muffin_http_cache_bytes` was measuring a directory nothing writes
#      to: frozen at 202,500,789 bytes / 1,031 entries since 2026-08-26 while the live cache had
#      grown to 596 MB / 3,206 entries. A gauge that stops moving looks exactly like a cache that
#      stopped growing. The root is now ASKED of docker, so the next data-root move cannot freeze
#      it silently.
#
#   2. NOTHING PLOTTED IT ANYWAY. The "Cache size on disk" panel plotted
#      `node_filesystem_size_bytes - node_filesystem_avail_bytes` for /mnt/data — the whole
#      filesystem — under a title claiming it was the cache. Measured 2026-08-28 that is 9.4 GB of
#      which the cache is 0.6: **90% of it is muffin_supabase-db-data at 8.4 GB**. Which is why it
#      went DOWN from time to time — Postgres recycling WAL and vacuuming, nothing to do with a
#      cache. Same failure as the `rows_estimate.*` rename: a number that is not what its name says.
#
# TWO LANES, because the costs differ by two orders of magnitude (measured on the node):
#
#     du of every named volume    0.04s   -> every minute
#     du of /var/lib/containerd   3.72s   -> every 15 minutes
#
# The image store is 21.5 GB and lives on `/`, which is at 79% while /mnt/data sits at 11% — so it
# is worth watching and NOT worth paying 3.7s a minute for. node-exporter reads every *.prom in the
# directory, so two files is the whole mechanism.
set -eu

OUTDIR=/var/lib/node-exporter
MODE="${1:-fast}"

# Ask docker where its root is rather than assuming. Falls back to the default only if docker is
# unreachable, and a missing volumes directory then exits quietly rather than emitting zeros --
# a zero here would read as "the cache was emptied".
ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
[ -n "$ROOT" ] || ROOT=/var/lib/docker
VOLS="$ROOT/volumes"

emit() { printf '%s\n' "$1" >> "$TMP"; }

if [ "$MODE" = fast ]; then
  OUT="$OUTDIR/muffin_disk.prom"
  TMP="$OUT.tmp"
  : > "$TMP"
  [ -d "$VOLS" ] || exit 0

  emit "# HELP muffin_volume_bytes Size of a docker named volume on disk."
  emit "# TYPE muffin_volume_bytes gauge"
  # Named volumes only: an anonymous volume is a 64-hex id that tells a reader nothing and churns
  # on every redeploy, which would make the series cardinality grow without bound.
  for d in "$VOLS"/*/_data; do
    [ -d "$d" ] || continue
    name=$(basename "$(dirname "$d")")
    case "$name" in
      *[!0-9a-f]*) ;;                     # has a non-hex char => a real name, keep it
      ????????????????????????????????*) continue ;;   # 32+ hex chars => anonymous, skip
    esac
    b=$(du -sb "$d" 2>/dev/null | cut -f1) || continue
    [ -n "$b" ] && emit "muffin_volume_bytes{volume=\"$name\"} $b"
  done

  # The http-cache keeps its own two series because the ENTRY COUNT has no analogue elsewhere:
  # bytes alone cannot distinguish a cache holding four enormous SEC companyfacts payloads from
  # one holding forty thousand small OpenFIGI answers, and those are very different states.
  CACHE="$VOLS/muffin_http-cache-data/_data"
  if [ -d "$CACHE" ]; then
    b=$(du -sb "$CACHE" 2>/dev/null | cut -f1)
    # nginx stores one FILE per entry under levels=1:2, so a file count is an entry count.
    n=$(find "$CACHE" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ -n "$b" ]; then
      emit "# HELP muffin_http_cache_bytes Size of the http-cache volume on disk."
      emit "# TYPE muffin_http_cache_bytes gauge"
      emit "muffin_http_cache_bytes $b"
      emit "# HELP muffin_http_cache_entries Cached responses held on disk (one file per entry)."
      emit "# TYPE muffin_http_cache_entries gauge"
      emit "muffin_http_cache_entries ${n:-0}"
    fi
  fi
else
  OUT="$OUTDIR/muffin_disk_slow.prom"
  TMP="$OUT.tmp"
  : > "$TMP"
  emit "# HELP muffin_path_bytes Size of a host directory that is not a docker volume."
  emit "# TYPE muffin_path_bytes gauge"
  # containerd's root: with the containerd image store there is NO data-root override, so images
  # land here whatever docker's DockerRootDir says. This is what grows `/` on every image pull.
  for p in /var/lib/containerd /var/lib/docker; do
    [ -d "$p" ] || continue
    b=$(du -sb "$p" 2>/dev/null | cut -f1) || continue
    [ -n "$b" ] && emit "muffin_path_bytes{path=\"$p\"} $b"
  done
fi

# Atomic: node-exporter reads on ITS schedule, and a half-written file makes it drop the WHOLE
# scrape with a parse error rather than skip one metric.
[ -s "$TMP" ] && mv "$TMP" "$OUT" || rm -f "$TMP"
