#!/usr/bin/env python3
"""A COLLECTOR NOBODY PLOTS AND A PANEL NOTHING FEEDS ARE BOTH INVISIBLE FAILURES.

Measured 2026-08-28, all three of these were true at once:

  * `muffin-cache-size.sh` emitted `muffin_http_cache_bytes` and NO PANEL PLOTTED IT.
  * The panel titled "Cache size on disk" plotted `node_filesystem_size - node_filesystem_avail`
    for /mnt/data -- the whole filesystem, 90% of which is the Postgres volume -- so it moved for
    reasons that had nothing to do with a cache.
  * Because nothing plotted the real metric, nobody noticed the collector was reading a STALE
    /var/lib/docker path and had been frozen at 202 MB since 2026-08-26 while the live cache grew
    to 596 MB.

An unplotted metric cannot be seen to be wrong -- the same shape as "a resource that is never
invoked cannot fail, and an unread view cannot be wrong", which this deployment has already hit
with `exchange-listings` and `untracked_listing`.

So the two sets must match: every `muffin_*` gauge a collector emits is plotted somewhere, and
every `muffin_*` metric a panel references is emitted by some collector.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
COLLECTORS = ROOT / "stack/observability/collectors"
DASH = ROOT / "stack/observability/grafana/dashboards"
RULES = ROOT / "stack/observability/prometheus"
# NOT ONLY THE TEXTFILE COLLECTORS. http-cache exposes its own /metrics from OpenResty Lua, so
# nginx.conf is an emitter too -- the first version of this check missed it and reported three
# working provider panels as unfed.
PROXY = ROOT / "stack/proxy"

# Emitted as a bare metric name at the start of a line, or via a HELP/TYPE declaration.
EMIT = re.compile(r"^\s*(?:#\s*(?:HELP|TYPE)\s+)?(muffin_[a-z0-9_]+)", re.M)
# Also catch python collectors building names in f-strings / literals.
EMIT_PY = re.compile(r"['\"](muffin_[a-z0-9_]+)")
REF = re.compile(r"(muffin_[a-z0-9_]+)")

def main() -> int:
    emitted = set()
    for f in sorted(COLLECTORS.glob("*")):
        if f.is_dir() or f.suffix not in (".sh", ".py"):
            continue
        txt = f.read_text()
        emitted |= set(EMIT.findall(txt)) | set(EMIT_PY.findall(txt))
    for f in sorted(PROXY.rglob("*.conf")):
        emitted |= set(EMIT_PY.findall(f.read_text()))
    # `_total` counters are exposed by prometheus with no suffix change, but a panel may use
    # rate()/increase() on the base name -- normalise so the comparison is about the metric.
    # ONLY PromQL, never the whole file. Reading raw JSON matched `muffin_supabase-db-data` inside
    # a panel DESCRIPTION and reported `muffin_supabase` as an unfed metric -- a guard crying wolf
    # on prose is a guard someone disables.
    referenced = set()
    for f in sorted(DASH.glob("*.json")):
        d = json.loads(f.read_text())
        for panel in d.get("panels", []):
            for t in panel.get("targets") or []:
                referenced |= set(REF.findall(t.get("expr") or ""))
    for f in list(RULES.rglob("*.yml")) + list(RULES.rglob("*.yaml")):
        referenced |= set(REF.findall(f.read_text()))

    if not emitted:
        print("FAIL: no muffin_* metrics found in any collector — the check is looking in the wrong place")
        return 1

    # A HISTOGRAM IS ONE METRIC IN THREE SERIES. Prometheus emits `_bucket`, `_sum` and `_count`
    # for every histogram; a latency panel uses `histogram_quantile` over `_bucket` alone. Treating
    # the other two as unplotted would demand decorative panels for series that are part of the
    # histogram's contract -- so they count as plotted when their `_bucket` is.
    for m in list(emitted):
        for suffix in ("_sum", "_count"):
            if m.endswith(suffix) and (m[: -len(suffix)] + "_bucket") in referenced:
                referenced.add(m)

    # THE ROOT CAUSE WAS A HARDCODED DOCKER ROOT. `muffin-cache-size.sh` read
    # /var/lib/docker/volumes/... while docker's data-root on this node is /mnt/data/docker, so it
    # measured a stale pre-migration directory: frozen at 202 MB since 2026-08-26 while the live
    # cache reached 596 MB. Nothing could report it -- the collector was succeeding. Ask docker
    # (`docker info --format {{.DockerRootDir}}`) instead of assuming, or the next data-root move
    # freezes a gauge silently all over again. Referring to the paths in a COMMENT is fine; a
    # collector may also name /var/lib/docker as a measurement TARGET, which is why the test is on
    # a path that continues into `/volumes`.
    root_bugs = []
    for f in sorted(COLLECTORS.glob("*")):
        if f.is_dir() or f.suffix not in (".sh", ".py"):
            continue
        for i, line in enumerate(f.read_text().splitlines(), 1):
            code = line.split("#", 1)[0]
            if re.search(r"/(var/lib|mnt/data)/docker/volumes", code):
                root_bugs.append(f"{f.name}:{i}: hardcodes a docker volumes path: {code.strip()[:80]}")
    for b in root_bugs:
        print(f"FAIL: {b}")
        print("      Resolve it from `docker info --format '{{.DockerRootDir}}'` instead.")

    unplotted = sorted(emitted - referenced)
    unfed = sorted(referenced - emitted)
    for m in unplotted:
        print(f"FAIL: {m} is emitted by a collector but NO panel or alert rule plots it.")
        print("      An unplotted metric cannot be seen to be wrong. Plot it, or stop collecting it.")
    for m in unfed:
        print(f"FAIL: {m} is referenced by a panel or alert but NO collector emits it.")
        print("      The panel will read 'No data' for ever. Fix the name, or add the collector.")
    print(f"checked {len(emitted)} emitted and {len(referenced)} referenced muffin_* metrics; "
          f"{len(unplotted)} unplotted, {len(unfed)} unfed")
    return 1 if (unplotted or unfed or root_bugs) else 0

if __name__ == "__main__":
    sys.exit(main())
