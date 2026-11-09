#!/usr/bin/env python3
"""One fiscal period must be one point, in production.

Two guards, because migration 126 can be right and still not be enough.

1. THE SERVING VIEW MUST HAVE COLLAPSED. `security_metric_series` is what the chart reads. If two
   rows for one (security, metric, period_type) sit within seven days of each other, the collapse
   is not applied — the migration did not reach this database, or its ordering was rewritten.

2. THE RAW TABLE MUST NOT DRIFT PAST THE WINDOW. RE-KEYED ON FISCAL LABELS 2026-11-07 (Phase 5 step
   11): a pair whose rows BOTH carry a fiscal label is two years the calendar called different, so
   one under 300 days apart is a calendar defect and fails outright. A pair with an unlabelled row
   is a row the calendar placed off the year (decision 11 keeps such rows stored, out of series):
   counted and reported, never failed. That count replaces the tripwire below, which crept from
   113 to 122 as weekly waves promoted Korean REITs whose six-month years Yahoo calls annual.
   Measured 2026-11-07: 123 pairs, 121 with an unlabelled row, and the two labelled ones (Magnera,
   Republic Airways) were successor calendars overlapping by a quarter, fixed in muffin-ingest#164.

   The history below is the tripwire's. The collapse spans seven days, which covers every
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
   did not: the primary key serves `metric_code, period_type` ordered by `security_id, as_of`. A
   regression is now a count that GROWS past the known one.

   PAGED BY KEY, NOT BY OFFSET. An offset page re-reads every row before it, so the cost grew with
   the table until a page passed the 8-second ceiling: measured 2026-10-29, the page at offset
   70,000 took 12.3 s and the same page from `security_id > x` took 6 ms. This check was cancelled
   at 57014 on every run from at least 2026-10-23 to 10-29, which kept market-verify red for a week.

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

BASE = os.environ.get("BASE", "").rstrip("/")
SRV = os.environ.get("SRV", "")
UA = "muffin-market-verify/1.0"

# A flow metric with wide coverage. Revenue is reported by every filer and by both sources, which
# is what makes it the metric most likely to be duplicated.
METRIC = "revenue"
SAMPLE = 1000
# Genuine consecutive annual periods are ~365 days apart. Below 300 they are the same fiscal year.
SAME_YEAR_MAX = 300
COLLAPSE_WINDOW = 7

# THE KNOWN BACKLOG of the raw half, as it was until the re-key on fiscal labels (2026-11-07). Kept
# as the history of why the count went; nothing reads it.
#
# 113 -> 120 on 2026-10-29, the first run that reached this count since 2026-10-23 (the offset
# paging timed out before it). Which seven are new cannot be told (the edge rewrites `fetched_at`),
# but the 25 most recently written pairs, read row by row, are the same kinds as the 113:
# six-month fiscal years Yahoo reports as annual for two Korean REITs (348950.KS, 330590.KS) and
# RPL.AX, Sigma Healthcare's move from a January to a June year end (SIG.AX), two dates for one
# ABF.L year, and SEC comparatives off the filer's calendar that the edge's sec-xbrl handler writes
# (LAKE, MYO, RCEL, MRDN, TBCH, RJET, BRT, AREC, RDNW). Phase 5 step 11 re-keys this check on
# fiscal labels and retires the constant.
#
# 120 -> 122 on 2026-11-04 (121 on 11-03). One is 355690.KQ, a KOSDAQ REIT the 11-02 promotion
# wave added, whose statements arrived 11-04: Yahoo serves its six-month years as annual, the
# 348950.KS kind. The other cannot be told apart, for the same reason as on 10-29. Read the same
# evening, the pairs are all known kinds, and in 120 of the 122 at least one row carries no fiscal
# label, i.e. the calendar has already judged it off the year. Every weekly wave can promote more
# such REITs, so this constant will keep creeping until the re-key on labels lands.
PAGE = 1000

# A ROTATING SIXTEENTH OF THE UNIVERSE, BY THE FIRST HEX DIGIT OF `security_id`, NEVER THE WHOLE
# SERIES. To return 1,000 rows ordered by security, the view resolves every symbol first: ~49,000
# revenue rows for 12,385 symbols. Measured 2026-10-04, that is 0.6 s warm and 6.4 s through
# PostgREST with a cold cache, under the 8-second ceiling of `authenticator`; it was cancelled
# there twice that day (10:00 and 18:27 UTC). The range pushes into the view, so a sixteenth
# resolves ~4,700 rows: 1.25 s on a cold range. The day picks the sixteenth, so sixteen days
# cover every security.
#
# NOW A 256TH, BY THE FIRST TWO HEX DIGITS. The view clusters a fiscal period across all of a
# security's metrics (#441), so the `revenue` filter cannot reach below its windows: a sixteenth
# read every annual metric of 791 securities, 128,739 rows, to return 1,000. The SEC history of
# 2026-11-07 multiplied those rows. Measured 2026-11-09: 0.85 s warm, 4.1 s cold, and past the
# 8-second ceiling inside the SEC filer tick, where market-verify runs (57014 at 11:57 UTC). A 256th
# is ~40 securities and ~290 annual revenue points, 51-214 ms. The check is structural (the
# collapse is applied or it is not), so a smaller daily sample loses nothing; 256 days cover every
# id.
_SLICE = datetime.date.today().toordinal() % 256
RANGE = f"&security_id=gte.{_SLICE:02x}000000-0000-0000-0000-000000000000" + (
    f"&security_id=lt.{_SLICE + 1:02x}000000-0000-0000-0000-000000000000" if _SLICE < 255 else ""
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
    """Every row, a page at a time from the last whole security, until a short page.

    `PGRST_DB_MAX_ROWS` is 1,000, and a limit above it is silently a shorter answer (CLAUDE.md), so
    the page is that size and the loop, not the limit, decides when the table has ended. A full
    page usually ends part-way through a security, so its last security is dropped and the next
    page starts at it: no row is skipped or read twice, and every security's rows arrive together.
    `path` must be ordered by `security_id` first.
    """
    rows = []
    after = None
    while True:
        page = get(f"{path}&limit={PAGE}" + (f"&security_id=gt.{after}" if after else ""))
        if len(page) < PAGE:
            rows.extend(page)
            return rows
        last = page[-1]["security_id"]
        whole = [r for r in page if r["security_id"] != last]
        if not whole:
            print(f"::error::one security fills a page of {PAGE}; the keyset cannot advance")
            sys.exit(1)
        rows.extend(whole)
        after = whole[-1]["security_id"]


def _self_test() -> int:
    """The keyset against an in-memory table whose pages end mid-security: every row exactly once."""
    global get, PAGE
    table = [{"security_id": f"{i // 3:04d}", "as_of": f"2020-01-0{i % 3 + 1}"} for i in range(20)]

    def fake(path: str):
        after = path.split("security_id=gt.")[1] if "security_id=gt." in path else ""
        return [r for r in table if r["security_id"] > after][:PAGE]

    real_get, real_page = get, PAGE
    get, PAGE = fake, 4
    try:
        got = get_all("security_metric?select=x&order=security_id,as_of")
    finally:
        get, PAGE = real_get, real_page
    if got != table:
        print(f"::error::self-test: the keyset read {len(got)} rows of {len(table)}, or reordered")
        return 1
    print(f"  ok   self-test: {len(table)} rows read once each across pages of 4")

    # The rules must DISAGREE on the fixture: a labelled pair 273 days apart fails, an unlabelled
    # one is only counted, a pair inside the window is the view's, and a year apart is two years.
    key = ("security_id", "metric_code", "period_type")
    rows = [
        {"security_id": "a", "metric_code": "revenue", "period_type": "annual", "as_of": d, "fiscal_year": fy}
        for d, fy in (("2022-12-31", 2022), ("2023-09-30", 2023), ("2024-09-28", 2024))
    ] + [
        {"security_id": "b", "metric_code": "revenue", "period_type": "annual", "as_of": d, "fiscal_year": fy}
        for d, fy in (("2022-12-31", 2022), ("2023-09-30", None), ("2023-10-02", 2023))
    ]
    labelled, unlabelled, within = classify(rows, key)
    if (len(labelled), len(unlabelled), within) != (1, 1, 1):
        print(f"::error::self-test: classified {len(labelled)} labelled, {len(unlabelled)} "
              f"unlabelled and {within} within the window; expected 1, 1 and 1")
        return 1
    print("  ok   self-test: a labelled pair fails, an unlabelled one is counted, the window is the view's")
    return 0


def pairs_by_gap(rows, key_fields):
    """Consecutive same-key period ends, as (key, gap_days)."""
    for key, gap, _ in labelled_pairs(rows, key_fields):
        yield key, gap


def labelled_pairs(rows, key_fields):
    """Consecutive same-key period ends, as (key, gap_days, both rows carry a fiscal label)."""
    by = collections.defaultdict(list)
    for r in rows:
        by[tuple(r[k] for k in key_fields)].append(
            (datetime.date.fromisoformat(r["as_of"]), r.get("fiscal_year") is not None)
        )
    for key, points in by.items():
        points.sort()
        for (a, la), (b, lb) in zip(points, points[1:]):
            yield key, (b - a).days, la and lb


def classify(rows, key_fields):
    """The raw half's verdict: (labelled pairs past the window, unlabelled ones, within it)."""
    labelled, unlabelled, within = [], [], 0
    for key, gap, both in labelled_pairs(rows, key_fields):
        if gap <= COLLAPSE_WINDOW:
            within += 1
        elif gap < SAME_YEAR_MAX:
            (labelled if both else unlabelled).append((key, gap))
    return labelled, unlabelled, within


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
              f"ids {_SLICE:02x}…)")

    # 2. The raw table, past the window: the WHOLE table, paged, against the known count.
    raw = get_all(
        "security_metric?select=security_id,metric_code,period_type,as_of,fiscal_year"
        f"&metric_code=eq.{METRIC}&period_type=eq.annual&order=security_id,as_of"
    )
    if not raw:
        print("::error::security_metric returned no annual rows — the check verified nothing")
        return 1
    if not any(r.get("fiscal_year") is not None for r in raw):
        print("::error::no annual row carries a fiscal label — the labelled half verified nothing")
        return 1
    labelled, unlabelled, within = classify(raw, ("security_id", "metric_code", "period_type"))
    if labelled:
        print(f"::error::{len(labelled)} pair(s) of LABELLED annual periods are {COLLAPSE_WINDOW}-"
              f"{SAME_YEAR_MAX} days apart in {len({k[0] for k, _ in labelled})} securities — two "
              "fiscal years the calendar says are different, closer than a year: a calendar defect")
        for (sid, mc, pt), gap in labelled[:10]:
            print(f"::error::  {sid[:8]} {mc}: {gap} days apart")
        fail = 1
    else:
        print(f"  ok   no labelled annual pair is closer than a year ({len(raw)} rows, the whole "
              f"table; {within} pair(s) inside the window, collapsed by the view)")
    print(f"::notice::{len(unlabelled)} annual pair(s) beyond the window have an unlabelled row in "
          f"{len({k[0] for k, _ in unlabelled})} securities: rows the calendar placed off the year, "
          "kept stored and out of series (decision 11). A gauge, not a failure.")

    return fail


if __name__ == "__main__":
    sys.exit(_self_test() if "--self-test" in sys.argv else main())
