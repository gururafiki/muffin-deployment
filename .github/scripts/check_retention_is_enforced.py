#!/usr/bin/env python3
"""Is the data that is supposed to be DELETED actually being deleted?

Every other check here asserts that data EXISTS and is shaped correctly. None of them can see a
retention rule that has stopped running, because a table that only grows looks exactly like a
healthy one — the counts go up, the floors stay green, and the rows nobody meant to keep accumulate
until something slow gets slower.

Five bounded tables have such a rule, and every one is enforced by application code rather than by
the database, which is precisely why they need watching from outside:

  * `earnings_calendar` prunes at 90 days. It is a CALENDAR, not an archive of every earnings date
    ever announced — 90 days of history so a page can say "reported on the 26th" as well as
    "reports on the 26th".
  * `security_news` is bounded to 90 days for the same reason.
  * `refresh_run`, `backlog_sample` and `universe_sample` prune at 400 days — a full year plus
    margin, so a year-on-year comparison always has both ends. 16 samples a day across 26 backlogs
    and ~148 universe metrics is ~2,800 rows a day, which is small until it is left for two years.

The delete path in each runs only when its resource runs, so a resource that starts failing, or a
cutoff someone edits, silently turns a bounded table into an unbounded one. Verified by hand once
(a row seeded 200 days back was pruned on the next run and a 30-day row survived); this is what
keeps that true.

The threshold is deliberately LOOSER than each rule — a 30-day grace on top of the retention, so
120 days for the 90-day tables and 430 for the 400-day ones. A row a few days past the cutoff means
the resource has not run since yesterday, which `check_resource_health` already reports and reports
better. A row a MONTH past it means the delete is not happening at all, which is what this is for.
"""
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ["BASE"].rstrip("/")
SRV = os.environ["SRV"]
UA = "muffin-market-verify/1.0"

# (table, date column, retention days as documented in the resource)
BOUNDED = [
    ("earnings_calendar", "report_date", 90),
    ("security_news", "published_at", 90),
    # The observability tables (migration 127). 400 days so a year-on-year comparison always has
    # both ends, pruned by `market.prune_observability` — which is called from inside the
    # `observability-sample` resource, exactly like the two above and for the same reason: a prune
    # with nowhere to be called from is a prune that stops happening.
    #
    # These are the ones MOST likely to grow unnoticed, because they are the ones nobody looks at
    # except through a dashboard that only ever plots a recent window.
    ("refresh_run", "started_at", 400),
    ("backlog_sample", "sampled_at", 400),
    ("universe_sample", "sampled_at", 400),
]
# Slack over the documented retention, so a late cron is not reported as a broken delete.
GRACE_DAYS = 30


def count_older_than(table: str, column: str, cutoff: str) -> int | None:
    """Rows strictly older than `cutoff`, via content-range rather than a page.

    A page would be capped at PGRST_DB_MAX_ROWS and report 1000 however bad things got — this
    repository has been bitten by exactly that three times, once in a guard that was itself
    measuring with a page.
    """
    url = f"{BASE}/rest/v1/{table}?select={column}&{column}=lt.{cutoff}"
    req = urllib.request.Request(
        url,
        headers={
            "apikey": SRV,
            "Authorization": f"Bearer {SRV}",
            "Accept-Profile": "market",
            "Prefer": "count=exact",
            "Range": "0-0",
            # urllib's default User-Agent gets a 403 from Cloudflare, which reads exactly like an
            # auth failure and is not.
            "User-Agent": UA,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            rng = r.headers.get("content-range", "")
    except urllib.error.HTTPError as exc:
        print(f"::warning::{table}: {exc.code} reading retention window")
        return None
    except Exception as exc:  # noqa: BLE001
        print(f"::warning::{table}: {exc} reading retention window")
        return None
    if "/" not in rng:
        return None
    total = rng.rsplit("/", 1)[1]
    return None if total == "*" else int(total)


def main() -> int:
    failures = 0
    for table, column, retention in BOUNDED:
        cutoff_day = datetime.date.today() - datetime.timedelta(days=retention + GRACE_DAYS)
        n = count_older_than(table, column, cutoff_day.isoformat())
        if n is None:
            print(f"  ??  {table}: could not measure")
            continue
        if n > 0:
            failures += 1
            print(
                f"::error::{table} holds {n} row(s) older than {cutoff_day} — retention is "
                f"{retention} days and the prune runs inside the resource, so this means the "
                f"delete has stopped happening, not that the cron is late"
            )
        else:
            print(f"  ok  {table}: nothing older than {cutoff_day} ({retention}d + {GRACE_DAYS}d grace)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
