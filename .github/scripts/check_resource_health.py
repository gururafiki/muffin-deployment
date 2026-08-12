#!/usr/bin/env python3
"""Is any refresh resource broken, as opposed to the DATA being wrong?

Every other check in market-verify.yml asserts the shape of the data, which cannot see a resource
that fails on every run: the table simply stops growing, and a floor set below the current value
stays green for weeks. Both failures found on 2026-08-12 were exactly that — a currency foreign key
and a missing grant, each breaking a resource completely while every count stayed plausible.

A SINGLE failure is not reported. Providers rate-limit and time out, and a check that cries wolf on
a blip gets ignored. This fires only when a resource has not SUCCEEDED in 12 hours; with the warm-up
running every 3 hours that is four consecutive misses, which is a broken resource rather than a bad
afternoon.

Reads refresh_log on stdin (PostgREST JSON). Exits 1 and prints the offenders if any.
"""
import datetime
import json
import sys

STALE_AFTER_HOURS = 12
# The in-flight TTL is 2 minutes, so an hour without finishing is a worker that died, not one busy.
IN_FLIGHT_HOURS = 1


def main() -> int:
    try:
        rows = json.load(sys.stdin)
    except Exception as exc:  # noqa: BLE001 - any parse failure means we cannot judge health
        print(f"could not read refresh_log: {exc}")
        return 1
    if isinstance(rows, dict):
        print(f"refresh_log read failed: {str(rows)[:120]}")
        return 1

    now = datetime.datetime.now(datetime.timezone.utc)
    bad: list[str] = []
    for r in rows:
        resource = r.get("resource", "?")
        if not r.get("finished_at"):
            started = datetime.datetime.fromisoformat(r["started_at"])
            hours = (now - started).total_seconds() / 3600
            if hours > IN_FLIGHT_HOURS:
                bad.append(f"{resource} (in flight {hours:.0f}h — the worker died)")
            continue
        if r.get("ok") is False or r.get("error"):
            finished = datetime.datetime.fromisoformat(r["finished_at"])
            hours = (now - finished).total_seconds() / 3600
            if hours > STALE_AFTER_HOURS:
                bad.append(f"{resource}: {str(r.get('error'))[:70]} (last ran {hours:.0f}h ago)")

    if bad:
        print(" | ".join(bad))
        return 1
    print(f"every resource has succeeded within {STALE_AFTER_HOURS}h")
    return 0


if __name__ == "__main__":
    sys.exit(main())
