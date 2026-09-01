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

READS `market.resource_health`, NOT `refresh_log`, AND THAT IS THE WHOLE POINT OF THE REWRITE.
`refresh_log` holds ONE ROW PER RESOURCE, overwritten on every run. The old version flagged a null
`finished_at` only once `started_at` was an hour old — but a resource on a five-minute cron
restarts every five minutes, so `started_at` is ALWAYS fresh. **A resource whose worker dies on
every single run therefore looks perpetually just-started**, and this check skipped it in silence.
Measured 2026-09-01: `security-segments` had been killed by the supervisor on every firing for two
days, and this returned "every resource has succeeded within 12h".

`resource_health` (migration 167) answers when a resource last did WORK — a successful run that was
not a skip. That catches all four shapes at once: dying every run, failing every run, skipping every
run, and never running at all.

Reads market.resource_health on stdin (PostgREST JSON). Exits 1 and prints the offenders.
"""
import datetime
import json
import sys

STALE_AFTER_HOURS = 12


def main() -> int:
    try:
        rows = json.load(sys.stdin)
    except Exception as exc:  # noqa: BLE001 - any parse failure means we cannot judge health
        print(f"could not read resource_health: {exc}")
        return 1
    if isinstance(rows, dict):
        print(f"resource_health read failed: {str(rows)[:120]}")
        return 1

    now = datetime.datetime.now(datetime.timezone.utc)
    bad: list[str] = []
    for r in rows:
        resource = r.get("resource", "?")
        first_seen = r.get("first_seen")
        last_worked = r.get("last_worked")

        # COLD-START GUARD. A resource we have only been recording for an hour CANNOT have been
        # broken for twelve, and without this every fresh deployment reports half its resources
        # broken for half a day — which is how the first alert anyone sees becomes one they ignore.
        if not first_seen:
            continue
        recorded_h = (now - datetime.datetime.fromisoformat(first_seen)).total_seconds() / 3600
        if recorded_h < STALE_AFTER_HOURS:
            continue

        if not last_worked:
            bad.append(f"{resource}: has NEVER done work in the recorded window "
                       f"({recorded_h:.0f}h) — only skips or failures")
            continue

        hours = (now - datetime.datetime.fromisoformat(last_worked)).total_seconds() / 3600
        if hours <= STALE_AFTER_HOURS:
            continue

        # A resource answering skips while doing nothing is the specific shape that used to read as
        # healthy: the invocation succeeds, so anything counting `ok` is satisfied. Name it, because
        # "stalled" and "stalled while looking busy" are diagnosed differently.
        skips, runs = r.get("skips_6h") or 0, r.get("runs_6h") or 0
        if runs and skips == runs:
            bad.append(f"{resource}: no work in {hours:.0f}h, and all {runs} runs in the last 6h "
                       f"were SKIPS — its worker is dying and the in-flight lock is answering")
        else:
            bad.append(f"{resource}: no work in {hours:.0f}h ({runs} run(s) in the last 6h)")

    if bad:
        print(" | ".join(bad))
        return 1
    print(f"every resource has done work within {STALE_AFTER_HOURS}h")
    return 0


if __name__ == "__main__":
    sys.exit(main())
