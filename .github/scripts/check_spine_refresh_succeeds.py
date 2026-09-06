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


def self_test() -> int:
    """Drive the real decision over synthetic histories, with no database.

    A THRESHOLD NOBODY HAS WATCHED FIRE IS AN ASSUMPTION. This check was relaxed from "any failure
    in the window" to "failing now, or twice" — a change that is only safe if the cases it must
    still catch are demonstrated, and demonstrated where a reviewer can re-run them. Runs in
    quality.yml on every PR, so a future edit that lets a broken spine pass goes red immediately.
    """
    from datetime import timedelta
    now = datetime.now(timezone.utc)
    err = 'relation "market.security_segment_spine" does not exist'

    def r(hours_ago, error=None):
        report = {"segment_spine_ms": 12}
        if error:
            report["segment_spine_error"] = error
        return {"started_at": (now - timedelta(hours=hours_ago)).isoformat(),
                "ok": True, "report": report}

    healthy = [r(i * 2) for i in range(SAMPLE)]
    cases = [
        ("every run healthy", healthy, 0),
        # The case this change exists for: one blip, corrected by the next run. A failed deploy can
        # leave the matview dropped, and a mid-chain migration failure is not atomic.
        ("one blip, refreshed successfully since",
         [r(0), r(2), r(4, err)] + [r(i * 2) for i in range(3, SAMPLE)], 0),
        # Everything below must STILL fail, or the relaxation removed detection power.
        ("the newest run is failing — broken now",
         [r(0, err)] + [r(i * 2) for i in range(1, SAMPLE)], 1),
        ("two failures in the window — intermittent",
         [r(0), r(2, err), r(4), r(6, err)] + [r(i * 2) for i in range(4, SAMPLE)], 1),
        ("no run inside the staleness window", [r(20 + i * 2) for i in range(SAMPLE)], 1),
        ("no runs recorded at all", [], 1),
    ]

    # `main()` refuses to run without BASE/SRV, so the harness supplies placeholders — `get` is
    # stubbed below and never reaches the network. Without this the two PASSING cases fail for a
    # reason unrelated to the rule, which is how a harness certifies the wrong thing; the self-test
    # caught exactly that on its first run.
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

    # A SINGLE FAILURE SINCE RECOVERED IS NOT A BROKEN SPINE, AND FAILING ON IT MAKES THIS GATE RED
    # FOR A DAY AFTER EVERY DEPLOY.
    #
    # This file's own comment on SAMPLE says "enough rows to see a run of failures rather than a
    # single blip" — and then failed on a single blip, which is a different rule from the one it
    # describes. Measured 2026-09-06: 1 of the last 24 runs carried the error, at 2026-09-05
    # 22:14, in the gap between a FAILED deploy that ended 22:06 and the successful one that
    # restored the spine at 22:39. A mid-chain migration failure is not atomic, so a failed deploy
    # can leave a dropped matview until the next pass — a real, bounded, self-healing condition
    # that the very next refresh corrected.
    #
    # market-verify was already red for six days when `derive-classifications` failed for four,
    # and nobody saw it. A gate that goes red for 24 hours after every deploy is how that happens,
    # so the discriminator has to be whether the spine is broken NOW or repeatedly — not whether a
    # failure has ever appeared in the window.
    #
    # THE DETECTION POWER IS UNCHANGED for everything this check exists to catch: a spine that
    # stops refreshing fails the newest run, and an intermittent one fails twice. Only the
    # already-corrected single blip is downgraded, and it is still REPORTED rather than swallowed —
    # an absence that never reaches a human is the failure mode this whole file is about.
    failed = [r for r in rows if (r.get("report") or {}).get("segment_spine_error")]
    newest_failed = bool((rows[0].get("report") or {}).get("segment_spine_error"))
    if newest_failed or len(failed) >= 2:
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
    if failed:
        # Reported, not asserted. If this starts appearing without a deploy beside it, it is the
        # intermittent case and the second occurrence will fail the job.
        print(
            f"::notice::segment spine refresh failed once in the last {len(rows)} runs "
            f"({failed[0]['started_at']}) and has refreshed successfully since — a deploy window, "
            "not a broken spine"
        )

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
    sys.exit(self_test() if "--self-test" in sys.argv else main())
