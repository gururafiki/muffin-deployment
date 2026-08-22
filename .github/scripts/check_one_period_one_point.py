#!/usr/bin/env python3
"""One fiscal period must be one point, in production.

Two guards, because migration 126 can be right and still not be enough.

1. THE SERVING VIEW MUST HAVE COLLAPSED. `security_metric_series` is what the chart reads. If two
   rows for one (security, metric, period_type) sit within seven days of each other, the collapse
   is not applied — the migration did not reach this database, or its ordering was rewritten.

2. THE RAW TABLE MUST NOT DRIFT PAST THE WINDOW. The collapse spans seven days, which covers every
   duplicate measured on 2026-08-22 (18 pairs, all <= 3 days, all agreeing in value). A pair of
   ANNUAL periods 8-299 days apart is a fiscal year reported twice with a gap the window cannot
   see — a new source with a different convention, or a company that changed its year end. Zero
   today; this reports the number rather than assuming it stays zero.

Why this is not covered by the behaviour test: that test proves the RULE against a fixture. This
proves the rule is applied to the DATA, which is a different claim — the same distinction that let
`security_price` pass every migration pass and still be unreadable for want of a grant.
"""
import collections
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ["BASE"].rstrip("/")
SRV = os.environ["SRV"]
UA = "muffin-market-verify/1.0"

# A flow metric with wide coverage. Revenue is reported by every filer and by both sources, which
# is what makes it the metric most likely to be duplicated.
METRIC = "revenue"
SAMPLE = 1000
# Genuine consecutive annual periods are ~365 days apart. Below 300 they are the same fiscal year.
SAME_YEAR_MAX = 300
COLLAPSE_WINDOW = 7


def get(path: str):
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={"apikey": SRV, "Authorization": f"Bearer {SRV}",
                 "Accept-Profile": "market", "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b"[]")


def pairs_by_gap(rows, key_fields):
    """Consecutive same-key period ends, as (key, gap_days)."""
    by = collections.defaultdict(list)
    for r in rows:
        by[tuple(r[k] for k in key_fields)].append(datetime.date.fromisoformat(r["as_of"]))
    for key, dates in by.items():
        dates.sort()
        for a, b in zip(dates, dates[1:]):
            yield key, (b - a).days


def main() -> int:
    fail = 0

    # 1. The serving view.
    view = get(
        "security_metric_series?select=security_id,metric_code,period_type,as_of"
        f"&metric_code=eq.{METRIC}&period_type=eq.annual&limit={SAMPLE}"
        "&order=security_id,as_of"
    )
    if not view:
        print("::error::security_metric_series returned no annual rows — the check verified nothing")
        return 1
    collapsed = [(k, g) for k, g in pairs_by_gap(view, ("security_id", "metric_code", "period_type"))
                 if g <= COLLAPSE_WINDOW]
    if collapsed:
        print(f"::error::security_metric_series still has {len(collapsed)} fiscal period(s) plotted "
              f"twice within {COLLAPSE_WINDOW} days — the collapse is not applied to this database")
        for (sid, mc, pt), gap in collapsed[:5]:
            print(f"::error::  {sid[:8]} {mc} {pt}: two period ends {gap} day(s) apart")
        fail = 1
    else:
        print(f"  ok   security_metric_series: one point per fiscal period ({len(view)} rows sampled)")

    # 2. The raw table, past the window.
    raw = get(
        "security_metric?select=security_id,metric_code,period_type,as_of"
        f"&metric_code=eq.{METRIC}&period_type=eq.annual&limit={SAMPLE}"
        "&order=security_id,as_of"
    )
    drifted = [(k, g) for k, g in pairs_by_gap(raw, ("security_id", "metric_code", "period_type"))
               if COLLAPSE_WINDOW < g < SAME_YEAR_MAX]
    within = sum(1 for _, g in pairs_by_gap(raw, ("security_id", "metric_code", "period_type"))
                 if g <= COLLAPSE_WINDOW)
    if drifted:
        print(f"::error::{len(drifted)} annual pair(s) are {COLLAPSE_WINDOW}-{SAME_YEAR_MAX} days "
              "apart — one fiscal year reported twice with a gap the collapse cannot see")
        for (sid, mc, pt), gap in drifted[:5]:
            print(f"::error::  {sid[:8]} {mc}: {gap} days apart")
        fail = 1
    else:
        print(f"  ok   no annual period is duplicated beyond the collapse window "
              f"({within} pair(s) inside it, collapsed by the view)")

    return fail


if __name__ == "__main__":
    sys.exit(main())
