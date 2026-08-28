#!/usr/bin/env python3
"""A PANEL MUST NOT FILTER AWAY THE STATE IT EXISTS TO REVEAL.

Three defects of one shape, all found by a person looking at a dashboard and asking why
something they knew was there wasn't:

  * the country x sector table carried `limit 60` over a worst-first sort. 106 buckets cleared
    the size floor and the United States ranked 90-98 of them -- BECAUSE it is well covered. The
    only US row that survived was `US / unknown` at 0%, so the country with the best coverage in
    the universe appeared as the worst.
  * `Rows written per resource` filtered `written > 0`. A resource that stops writing is exactly
    what a throughput chart is for, and it was the one thing the panel could not draw --
    security-corporate-actions sat at written=0 for seven consecutive runs, invisible.
  * `Backlog depth by resource` filtered `depth > 0`, so a queue draining to completion vanished
    rather than showing that it had finished.

The rule: a cutoff is legitimate when it bounds an unbounded stream (a log tail, a top-N over
cardinality that would melt the browser). It is a bug when it is applied to a BOUNDED set that
the panel is claiming to summarise, because then the rows it drops are data the reader believes
they are seeing.

Panels that legitimately truncate declare it in ALLOWED below, with the reason.
"""
import json, pathlib, re, sys

# (dashboard title, panel title, THE EXACT CUTOFF) -> why that cutoff is sound.
#
# THE KEY INCLUDES THE EXPRESSION ON PURPOSE. Keyed on the panel alone, an exemption granted for
# one sound cutoff silently blesses every cutoff added to that panel afterwards -- which is how
# `limit 60` could reappear on the cross table, the panel that already holds a declared floor.
ALLOWED = {
    ("Muffin — Pipeline", "Recent failures", "limit 100"):
        "a log tail: append-only, newest-first, and 'recent' is the panel's whole claim",
    ("Muffin — Pipeline", "Worker budget headroom — seconds used of the 90s limit", "value > 20000"):
        "the 20s floor is the panel's SUBJECT (resources near the 90s budget), not a size cutoff",
    ("Muffin — Pipeline", "Provider throttle pressure", "count > 0"):
        "zero throttling is the healthy default for ~40 resources; the panel exists to show non-zero",
    ("Muffin — Data coverage", "Country × sector — completeness (sortable; worst first by default)",
     "securities >= $minsize"):
        "the floor is the $minsize VARIABLE, visible in the UI and selectable down to 1 — the "
        "reader chooses it, so nothing is hidden by a decision they cannot see",
    ("Muffin — Providers & cache", "Egress connections — which container called which host", "topk(25"):
        "topk over unbounded hostname cardinality; the long tail is genuinely not renderable",
}

TRUNCATION = re.compile(r"\blimit\s+(\d+)\b|topk\((\d+)", re.I)
# a numeric floor on a measured quantity -- the shape that deletes the zero row
# ZERO IS NOT AN EXEMPT FLOOR -- it is the defect's commonest form. `written > 0` reads as
# "ignore the empty rows" and means "never draw a resource that stopped working".
FLOOR = re.compile(r"\b(written|depth|value|securities|count|rows|total)\s*>=?\s*(\$?\w+)", re.I)

def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[2]
    dash = root / "stack/observability/grafana/dashboards"
    bad, checked = [], 0
    for f in sorted(dash.glob("*.json")):
        d = json.loads(f.read_text())
        title = d.get("title", f.stem)
        for panel in d.get("panels", []):
            for t in panel.get("targets") or []:
                q = " ".join((t.get("rawSql") or t.get("expr") or "").split())
                if not q:
                    continue
                checked += 1
                hits = [m.group(0) for m in TRUNCATION.finditer(q)]
                hits += [m.group(0) for m in FLOOR.finditer(q)]
                hits = [h for h in hits if (title, panel.get("title", "?"), h) not in ALLOWED]
                if hits:
                    bad.append((f.name, key[1], hits, q[:150]))
    if checked == 0:                      # anti-vacuity: a check that inspects nothing passes nothing
        print("FAIL: no panel queries found — the check is looking in the wrong place")
        return 1
    for fn, panel, hits, q in bad:
        print(f"FAIL {fn}: panel {panel!r} truncates or floors: {', '.join(hits)}")
        print(f"     {q}")
        print("     Either remove it, or add it to ALLOWED with the reason it cannot hide data.")
    print(f"checked {checked} panel queries across {len(list(dash.glob('*.json')))} dashboards; "
          f"{len(ALLOWED)} declared truncations; {len(bad)} undeclared")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
