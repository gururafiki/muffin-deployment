#!/usr/bin/env python3
"""One fiscal period must be one point, in production.

Two guards, because migration 126 can be right and still not be enough.

1. THE SERVING VIEW MUST HAVE COLLAPSED. `security_metric_series` is what the chart reads. If two
   rows for one (security, metric, period_type) sit within seven days of each other, the collapse
   is not applied — the migration did not reach this database, or its ordering was rewritten.

2. THE RAW TABLE MUST NOT DRIFT PAST THE WINDOW. The collapse spans seven days, which covers every
   duplicate measured on 2026-08-22 (18 pairs, all <= 3 days, all agreeing in value). A pair of
   ANNUAL periods 8-299 days apart is a fiscal year reported twice with a gap the window cannot
   see — a new source with a different convention, or a company that changed its year end.

   COUNTED OVER THE WHOLE TABLE AND TRIPWIRED, because the known ones are real company events the
   model cannot express yet. Measured 2026-10-10: 113 such pairs in 56 securities, out of 75,018
   annual revenue rows for 12,002 securities. Read row by row they are not duplicate fiscal years:
   a fiscal-year change with its transition period (Greif moved from October to September in 2024,
   Mistras from May to December in 2016), a merger whose CIK carries both companies' calendars
   (Bristow and Era), a mis-tagged XBRL fact (ESCO's "annual" 2019-07-02 of $37M) and a zero from
   Yahoo (TIC Solutions, 2023-11-30). They belong to Phase 5's fiscal-period model.

   This half used to read the first 1,000 rows of a rotating sixteenth and fail on ANY pair. So the
   gate went red or green with the day's digit — red on 2026-10-06, 10-08, 10-09 and 10-10, green in
   between, on unchanged data — which is exactly the gate nobody reads (CLAUDE.md, 2026-09-06), and
   it covered ~1,000 of 75,018 rows a day. The raw table answers this cheaply where the serving view
   did not: the primary key serves `metric_code, period_type` ordered by `security_id, as_of`, so all
   76 pages cost a few seconds. A regression is now a count that GROWS past the known one.

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

# THE KNOWN BACKLOG of the raw half, measured 2026-10-10 over the whole table (see the docstring).
# Raise it only with a note naming the new pairs; lower it as Phase 5 fixes them.
KNOWN_DRIFTED_PAIRS = 113
PAGE = 1000

# A ROTATING SIXTEENTH OF THE UNIVERSE, BY THE FIRST HEX DIGIT OF `security_id`, NEVER THE WHOLE
# SERIES. To return 1,000 rows ordered by security, the view resolves every symbol first: ~49,000
# revenue rows for 12,385 symbols. Measured 2026-10-04, that is 0.6 s warm and 6.4 s through
# PostgREST with a cold cache, under the 8-second ceiling of `authenticator`; it was cancelled
# there twice that day (10:00 and 18:27 UTC). The range pushes into the view, so a sixteenth
# resolves ~4,700 rows: 1.25 s on a cold range. The day picks the sixteenth, so sixteen days
# cover every security.
_DIGIT = datetime.date.today().toordinal() % 16
RANGE = f"&security_id=gte.{_DIGIT:x}0000000-0000-0000-0000-000000000000" + (
    f"&security_id=lt.{_DIGIT + 1:x}0000000-0000-0000-0000-000000000000" if _DIGIT < 15 else ""
)


def get(path: str):
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={"apikey": SRV, "Authorization": f"Bearer {SRV}",
                 "Accept-Profile": "market", "User-Agent": UA},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"[]")
    except urllib.error.HTTPError as e:
        # PostgREST names the cause in the body, and a traceback drops it: the 10:00 UTC failure on
        # 2026-10-04 was a bare 500, and only once this printed the body did it read 57014.
        print(f"::error::{path.split('?')[0]}: HTTP {e.code} {e.read().decode('utf-8', 'replace')[:300]}")
        sys.exit(1)


def get_all(path: str):
    """Every row, a page at a time, until a short page.

    `PGRST_DB_MAX_ROWS` is 1,000, and a limit above it is silently a shorter answer (CLAUDE.md), so
    the page is that size and the loop, not the limit, decides when the table has ended. The order
    is total — (security_id, as_of) is unique for one metric and period type, because both are in
    the primary key — so an offset cannot skip or repeat a row between pages.
    """
    rows = []
    while True:
        page = get(f"{path}&limit={PAGE}&offset={len(rows)}")
        rows.extend(page)
        if len(page) < PAGE:
            return rows


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
        f"&metric_code=eq.{METRIC}&period_type=eq.annual&limit={SAMPLE}{RANGE}"
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
        print(f"  ok   security_metric_series: one point per fiscal period ({len(view)} rows sampled, "
              f"ids {_DIGIT:x}…)")

    # 2. The raw table, past the window: the WHOLE table, paged, against the known count.
    raw = get_all(
        "security_metric?select=security_id,metric_code,period_type,as_of"
        f"&metric_code=eq.{METRIC}&period_type=eq.annual&order=security_id,as_of"
    )
    if not raw:
        print("::error::security_metric returned no annual rows — the check verified nothing")
        return 1
    gaps = list(pairs_by_gap(raw, ("security_id", "metric_code", "period_type")))
    drifted = [(k, g) for k, g in gaps if COLLAPSE_WINDOW < g < SAME_YEAR_MAX]
    within = sum(1 for _, g in gaps if g <= COLLAPSE_WINDOW)
    securities = len({k[0] for k, _ in drifted})
    if len(drifted) > KNOWN_DRIFTED_PAIRS:
        print(f"::error::{len(drifted)} annual pair(s) are {COLLAPSE_WINDOW}-{SAME_YEAR_MAX} days "
              f"apart in {securities} securities, above the {KNOWN_DRIFTED_PAIRS} known on "
              "2026-10-10 — a fiscal year reported twice with a gap the collapse cannot see")
        for (sid, mc, pt), gap in drifted[:10]:
            print(f"::error::  {sid[:8]} {mc}: {gap} days apart")
        fail = 1
    else:
        print(f"  ok   {len(drifted)} annual pair(s) beyond the collapse window in {securities} "
              f"securities, within the {KNOWN_DRIFTED_PAIRS} known ({len(raw)} rows, the whole "
              f"table; {within} pair(s) inside the window, collapsed by the view)")
        if len(drifted) < KNOWN_DRIFTED_PAIRS:
            print(f"::notice::the known backlog shrank to {len(drifted)} — lower "
                  "KNOWN_DRIFTED_PAIRS so the tripwire keeps its edge")

    return fail


if __name__ == "__main__":
    sys.exit(main())
