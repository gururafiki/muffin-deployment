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
# Two full cycles late before it is a fault. One missed cycle is a blip; the point of the TTL is
# that the resource is ALLOWED to be quiet for it.
TTL_CYCLES_BEFORE_STALE = 2.5


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

        # A RESOURCE NOTHING SCHEDULES CANNOT BE LATE. A retired one keeps its history for the
        # 30 days `resource_health` looks back over, so it goes on looking stalled long after it
        # was correctly switched off. `security-eps-history` was deleted from the cron by migration
        # 138 when the nasdaq earnings calendar replaced it, and was still being reported broken a
        # week later — sitting in the same list as the resources that really had stopped.
        #
        # `scheduled is None` means an older view that does not report it; treat that as scheduled
        # rather than silently exempting everything.
        if r.get("scheduled") is False:
            continue

        # COLD-START GUARD. A resource we have only been recording for an hour CANNOT have been
        # broken for twelve, and without this every fresh deployment reports half its resources
        # broken for half a day — which is how the first alert anyone sees becomes one they ignore.
        if not first_seen:
            continue
        recorded_h = (now - datetime.datetime.fromisoformat(first_seen)).total_seconds() / 3600
        if recorded_h < STALE_AFTER_HOURS:
            continue

        if not last_worked:
            # Same allowance: a 7-day-TTL resource that has not worked inside a 200h window has
            # missed barely one cycle, which is not evidence of a fault.
            ttl_h = r.get("ttl_hours")
            if ttl_h and recorded_h < float(ttl_h) * TTL_CYCLES_BEFORE_STALE:
                continue
            bad.append(f"{resource}: has NEVER done work in the recorded window "
                       f"({recorded_h:.0f}h) — only skips or failures")
            continue

        # LATE BY ITS OWN SCHEDULE, not by one global rule. A resource with a 7-day TTL is
        # supposed to be quiet for a week; measured 2026-09-04, judging every resource against a
        # flat 12 hours flagged eight, of which `fund-holdings` (7-day TTL, quarterly filings) and
        # `derive-classifications` (30-day) were behaving exactly as designed. The multiplier gives
        # a resource two whole cycles to miss before anyone is woken.
        ttl_hours = r.get("ttl_hours")
        threshold = STALE_AFTER_HOURS
        if ttl_hours:
            threshold = max(STALE_AFTER_HOURS, float(ttl_hours) * TTL_CYCLES_BEFORE_STALE)

        hours = (now - datetime.datetime.fromisoformat(last_worked)).total_seconds() / 3600
        if hours <= threshold:
            continue

        # A resource answering skips while doing nothing is the specific shape that used to read as
        # healthy: the invocation succeeds, so anything counting `ok` is satisfied. Name it, because
        # "stalled" and "stalled while looking busy" are diagnosed differently.
        skips, runs = r.get("skips_6h") or 0, r.get("runs_6h") or 0
        if runs and skips == runs:
            bad.append(f"{resource}: no work in {hours:.0f}h, and all {runs} runs in the last 6h "
                       f"were SKIPS — its worker is dying and the in-flight lock is answering")
        else:
            bad.append(f"{resource}: no work in {hours:.0f}h, threshold {threshold:.0f}h "
                       f"({runs} run(s) in the last 6h)")

    if bad:
        print(" | ".join(bad))
        return 1
    print(f"every resource has done work within {STALE_AFTER_HOURS}h")
    return 0


if __name__ == "__main__":
    sys.exit(main())
