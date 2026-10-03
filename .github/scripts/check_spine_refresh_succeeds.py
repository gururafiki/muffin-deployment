#!/usr/bin/env python3
"""A matview that stops refreshing serves stale data and reports success.

`security_segment_spine` is on a CORRECTNESS path: `derive_segment_classification` reads it
(migration 179 moved it there, 2,586 ms against 2.8 ms), as do the coverage segment facets and the
Business lines dashboard. If it silently stops refreshing, all of them freeze on its last snapshot
while every run still reports success.

That happened. Until 2026-10-03 the `facets-refresh` edge resource refreshed it as a PostgREST RPC,
one statement under the role's 8 s ceiling. It last succeeded on 2026-09-23 at 7,992 ms and timed
out 148 times in a row after that, while the resource recorded ok, deliberately: the screener's
spine had refreshed. This check failed every night from 09-30 on that, and nothing alerts on a
failing market-verify, so the spine stayed frozen for ten days.

It now refreshes from the pg_cron job `muffin-segment-spine` (:16, hourly) as `postgres`, and the
refresh RECORDS ITSELF as `segment_spine.duration_ms` in `universe_sample` (migration
20261003190000). A refresh that fails or times out rolls its own sample back, so the evidence is
the samples' AGE: an absent or old sample is a refresh that is not happening, whatever the reason.
The error text is in `cron.job_run_details`.

Two claims:
  1. a refresh was recorded at all, and recently
  2. the newest one is not walking toward the job's own bound — reported, not asserted, because a
     slow refresh that still finishes is a chart to watch rather than a failure

Deliberately NOT asserted: the row count. The spine tracks the segment table, so a floor here would
be a second, drifting copy of a number that legitimately moves.
"""
import contextlib
import io
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

# READ LAZILY, NOT AT IMPORT. `--self-test` needs no database, and a module-level lookup makes a
# missing variable kill the offline mode before argv is even parsed — exactly the defect
# `check_quarter_is_a_quarter` records.
BASE = os.environ.get("BASE", "").rstrip("/")
SRV = os.environ.get("SRV", "")
UA = "muffin-market-verify/1.0"

# The job runs hourly. Two missed runs plus margin before calling it stale: one late run is a
# deploy or a slow tick, three hours is the refresh not happening.
STALE_AFTER_HOURS = 3
# The job's own `statement_timeout`. Half of it is where a slow refresh becomes worth a look.
BOUND_MS = 300_000
SAMPLE = 12


def get(path):
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={"apikey": SRV, "Authorization": f"Bearer {SRV}",
                 "Accept-Profile": "market", "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def self_test() -> int:
    """Drive the real decision over synthetic histories, with no database.

    A THRESHOLD NOBODY HAS WATCHED FIRE IS AN ASSUMPTION. Runs in quality.yml on every PR, so a
    future edit that lets a frozen spine pass goes red immediately.
    """
    now = datetime.now(timezone.utc)

    def s(hours_ago, ms=7_500):
        return {"sampled_at": (now - timedelta(hours=hours_ago)).isoformat(), "value": ms}

    cases = [
        ("refreshed every hour", [s(i) for i in range(SAMPLE)], 0),
        ("one run missed, the next succeeded", [s(1.2)] + [s(2 + i) for i in range(SAMPLE - 1)], 0),
        ("fresh but slow — reported, not failed", [s(0.5, 200_000)] + [s(1 + i) for i in range(SAMPLE - 1)], 0),
        # Everything below must FAIL.
        ("the newest refresh is four hours old — stopped", [s(4 + i) for i in range(SAMPLE)], 1),
        ("frozen for days, the incident this replaced", [s(240 + i) for i in range(SAMPLE)], 1),
        ("no refresh ever recorded", [], 1),
    ]

    # `main()` refuses to run without BASE/SRV, so the harness supplies placeholders — `get` is
    # stubbed below and never reaches the network. Without this the passing cases fail for a reason
    # unrelated to the rule, which is how a harness certifies the wrong thing.
    global get, BASE, SRV
    real_get, real_base, real_srv, failures = get, BASE, SRV, 0
    BASE, SRV = BASE or "http://self-test", SRV or "self-test"
    try:
        for name, rows, want in cases:
            get = lambda _path, _rows=rows: _rows
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = main()
            mark = "ok  " if rc == want else "FAIL"
            if rc != want:
                failures += 1
            print(f"  {mark} {name} -> rc={rc}, wanted {want}")
    finally:
        get, BASE, SRV = real_get, real_base, real_srv

    print("  self-test passed" if failures == 0 else f"  {failures} self-test failure(s)")
    return 1 if failures else 0


def main():
    if not BASE or not SRV:
        print("::error::BASE and SRV must be set for the live check (use --self-test offline)")
        return 1
    try:
        rows = get(
            "universe_sample?metric=eq.segment_spine.duration_ms"
            f"&select=sampled_at,value&order=sampled_at.desc&limit={SAMPLE}"
        )
    except urllib.error.URLError as e:
        print(f"::error::spine refresh — could not read universe_sample: {e}")
        return 1

    if not rows:
        # A CHECK THAT VERIFIES NOTHING MUST NOT READ AS ONE THAT PASSED.
        print(
            "::error::segment spine — no refresh has ever been recorded. Read cron.job_run_details "
            "for muffin-segment-spine: a refresh that fails rolls its own sample back"
        )
        return 1

    newest = rows[0]
    at = datetime.fromisoformat(newest["sampled_at"].replace("Z", "+00:00"))
    age_h = (datetime.now(timezone.utc) - at).total_seconds() / 3600
    if age_h > STALE_AFTER_HOURS:
        print(
            f"::error::segment spine last refreshed {age_h:.1f}h ago, threshold "
            f"{STALE_AFTER_HOURS}h. derive_segment_classification, the coverage segment facets and "
            "the Business lines dashboard are reading a frozen snapshot. The error text is in "
            "cron.job_run_details for muffin-segment-spine"
        )
        return 1

    ms = float(newest.get("value") or 0)
    if ms > BOUND_MS / 2:
        print(
            f"::warning::segment spine refresh took {ms:,.0f} ms, over half the job's "
            f"{BOUND_MS:,} ms bound. It grows with security_segment"
        )
    print(f"  ok   segment spine: refreshed {age_h:.1f}h ago in {ms:,.0f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv else main())
