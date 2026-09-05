#!/usr/bin/env python3
"""A matview that stops refreshing serves stale data and reports success.

`facets-refresh` refreshes TWO spines. If `refresh_segment_spine` fails it records the error and
returns ok anyway — deliberately, and correctly: the filter spine the Markets tab and the screener
read has already refreshed by that point, and failing the whole resource would trade a stale
segment dashboard for a stale universe. Nothing asserted it, which was tolerable while the segment
spine only fed dashboards.

It is not tolerable now. Migration 179 moved `derive_segment_classification` onto
`security_segment_spine` — the view it used to read costs 2,586 ms unfiltered against the spine's
2.8 ms, which is what took that function from > 45,000 ms to 102 ms — so the spine is on a
CORRECTNESS path: if it silently stops refreshing, the weighted sector classification freezes at
whatever it last derived and every run still reports success. That is the same shape as the four
days of silent daily failure that migration 179 exists to fix, one level further out.

Two claims, because they fail differently:
  1. the most recent facets-refresh runs carried NO segment_spine_error
  2. the spine was actually rebuilt recently — a resource can succeed while doing nothing

Deliberately NOT asserted: the row count. The spine tracks the segment table, so a floor here would
be a second, drifting copy of a number that legitimately moves.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

BASE = os.environ["BASE"].rstrip("/")
SRV = os.environ["SRV"]
UA = "muffin-market-verify/1.0"

# facets-refresh runs every two hours. Three cycles of grace before calling it stale: one late run
# is a deploy or a skipped tick, three in a row is the refresh not happening.
STALE_AFTER_HOURS = 8
# Enough rows to see a run of failures rather than a single blip, and few enough to stay cheap.
SAMPLE = 12


def get(path):
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={"apikey": SRV, "Authorization": f"Bearer {SRV}",
                 "Accept-Profile": "market", "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def main():
    try:
        rows = get(
            "refresh_run?resource=eq.facets-refresh&skipped=is.false"
            f"&select=started_at,ok,report&order=started_at.desc&limit={SAMPLE}"
        )
    except urllib.error.URLError as e:
        print(f"::error::spine refresh — could not read refresh_run: {e}")
        return 1

    if not rows:
        # A CHECK THAT VERIFIES NOTHING MUST NOT READ AS ONE THAT PASSED.
        print("::error::spine refresh — no facets-refresh runs recorded at all")
        return 1

    failed = [r for r in rows if (r.get("report") or {}).get("segment_spine_error")]
    if failed:
        newest = failed[0]
        print(
            f"::error::segment spine refresh failed in {len(failed)} of the last {len(rows)} "
            f"facets-refresh runs — newest {newest['started_at']}: "
            f"{(newest.get('report') or {}).get('segment_spine_error')}"
        )
        print(
            "::error::  derive_segment_classification reads that spine, so its output freezes "
            "while every run still reports success"
        )
        return 1

    newest = rows[0]
    started = datetime.fromisoformat(newest["started_at"].replace("Z", "+00:00"))
    age_h = (datetime.now(timezone.utc) - started).total_seconds() / 3600
    if age_h > STALE_AFTER_HOURS:
        print(
            f"::error::segment spine last rebuilt {age_h:.1f}h ago, threshold {STALE_AFTER_HOURS}h "
            "— derive_segment_classification is deriving from a frozen snapshot"
        )
        return 1

    ms = (newest.get("report") or {}).get("segment_spine_ms")
    print(
        f"  ok   segment spine: rebuilt {age_h:.1f}h ago, no errors in the last {len(rows)} runs"
        + (f" ({ms} ms)" if ms is not None else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
