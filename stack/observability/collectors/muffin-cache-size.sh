#!/bin/sh
# Size AND ENTRY COUNT of the http-cache volume, for node-exporter's textfile collector.
#
# WHY IT IS A FILE. It was inline `copy: content:` in muffin_stack.yml, which Ansible renders
# through JINJA — the per-service python collector shipped that way and killed a deploy with
# `template error while templating string: expected name or number`. This script has no braces
# TODAY and the next edit might; `copy:` with a `src:` is copied verbatim.
#
# The entry count is the answer to "how many requests are cached". Bytes alone cannot distinguish
# a cache holding four enormous SEC companyfacts payloads from one holding forty thousand small
# OpenFIGI answers, and those are very different states.
set -eu

VOL=/var/lib/docker/volumes/muffin_http-cache-data/_data
OUT=/var/lib/node-exporter/muffin_http_cache.prom

[ -d "$VOL" ] || exit 0

BYTES=$(du -sb "$VOL" 2>/dev/null | cut -f1)
[ -n "$BYTES" ] || exit 0

# nginx stores one FILE per cache entry under levels=1:2, so a file count is an entry count.
ENTRIES=$(find "$VOL" -type f 2>/dev/null | wc -l | tr -d ' ')
[ -n "$ENTRIES" ] || ENTRIES=0

# Atomic: node-exporter reads on ITS schedule, and a half-written file makes it drop the WHOLE
# scrape with a parse error rather than skip one metric.
{
  echo "# HELP muffin_http_cache_bytes Size of the http-cache volume on disk."
  echo "# TYPE muffin_http_cache_bytes gauge"
  echo "muffin_http_cache_bytes $BYTES"
  echo "# HELP muffin_http_cache_entries Cached responses held on disk (one file per entry)."
  echo "# TYPE muffin_http_cache_entries gauge"
  echo "muffin_http_cache_entries $ENTRIES"
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
