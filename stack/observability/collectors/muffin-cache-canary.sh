#!/bin/sh
# The http-cache canary, for node-exporter's textfile collector. Run hourly by cron.
#
# Asks http-cache's `/canary` twice in a row and records whether the SECOND answer was a HIT. The
# first may be a MISS (the entry expired, or the cache was emptied) and that is fine; a second MISS
# means the cache did not store what it was just given. `/canary` is served by http-cache itself
# (see stack/proxy/nginx.conf), so no provider can fail it.
#
# WHY NOT THE HIT RATIO. The alert it replaces divided HITs by all cacheable requests, which is a
# measure of how much repeat traffic there is. On Saturday 2026-10-31 it fell under 5% and fired
# while a repeated SEC request logged MISS then HIT: the lanes now ask each question once, bypass
# the read or skip the store, so on a quiet day nobody repeats anything.
#
# A run that cannot ask (http-cache down, docker unreachable) records 0, not nothing: a canary
# that goes quiet must not read as one that passed. The timestamp lets the alert tell a stale
# file from a fresh one.
set -eu

OUT=/var/lib/node-exporter/muffin_cache_canary.prom
TMP="$OUT.tmp"

container=$(docker ps -qf name=muffin_http-cache 2>/dev/null | head -1 || true)

# busybox wget prints the response headers on stderr with -S; the status is the header's value.
ask() {
  [ -n "$container" ] || { echo NONE; return; }
  s=$(docker exec "$container" wget -S -q -O /dev/null http://127.0.0.1:8080/canary 2>&1 \
        | awk 'tolower($1) == "x-cache-status:" { v = $2 } END { print (v == "" ? "NONE" : v) }') \
    || s=NONE
  echo "$s"
}

first=$(ask)
second=$(ask)
hit=0
[ "$second" = HIT ] && hit=1

{
  echo "# HELP muffin_cache_canary_hit 1 when the second of two requests for http-cache's /canary was a HIT."
  echo "# TYPE muffin_cache_canary_hit gauge"
  echo "muffin_cache_canary_hit{first=\"$first\",second=\"$second\"} $hit"
  echo "# HELP muffin_cache_canary_timestamp_seconds When the canary last ran."
  echo "# TYPE muffin_cache_canary_timestamp_seconds gauge"
  echo "muffin_cache_canary_timestamp_seconds $(date +%s)"
} > "$TMP"
mv "$TMP" "$OUT"
