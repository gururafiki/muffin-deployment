"""A quarterly figure must be three months, not a year-to-date slice — measured across the POPULATION.

WHY THIS EXISTS. `security-xbrl` classified a fact as quarterly from its `fp` label and bounded the
duration on one side only. XBRL's Q2 and Q3 duration facts are frequently YEAR-TO-DATE — six and
nine months — and still carry `fp: "Q2"`. Measured in production before the fix:

    AAPL revenue  quarter  2026-03-28   254,940,000,000
    AAPL revenue  annual   2025-09-27   416,161,000,000

61% of a full year inside one quarter. The quarterly chart spiked every Q2, a TTM built on it would
have been badly wrong, and nothing in any row count showed it.

── WHY THIS IS NOT A PER-COMPANY RATIO, AFTER THREE ATTEMPTS THAT WERE ─────────────────────────

Comparing one quarter against its year fires on ordinary volatility, and this universe is full of
it. Every variant was tried against production and every one cried wolf:

  * quarter vs the largest annual, positives only  ->  13 flagged, all innocent
  * quarters summed vs the year                    ->  compared ZERO years: a SEC filer has THREE
                                                       quarterly filings, not four (10-Qs cover
                                                       Q1-Q3, the 10-K covers the year), so there
                                                       is no Q4 fact to sum
  * quarter vs its own year, with a materiality gate -> 46 flagged, still innocent

The clearest example: Teads Holding 2021 filed +10.7m, +15.2m and -53.9m against a +11.0m year.
Every positive quarter "exceeds" the annual and nothing is wrong — one quarter lost fifty million.
A ratio against a small residue is noise, and no threshold separates it from a six-month figure.

── THE CONTAMINATION IS SYSTEMATIC, SO MEASURE IT SYSTEMATICALLY ───────────────────────────────

YTD stacking is an INGEST defect, not a company defect: when it happens it happens to everyone at
once. Within a fiscal year the stored values become a, a+b, a+b+c — so the LAST quarter of the year
is about three times the first, for company after company.

Discrete quarters have no such relationship: the last quarter is sometimes bigger, sometimes
smaller, and the MEDIAN ratio across hundreds of companies sits near 1. Contaminated, it sits near
3. An individual volatile company moves its own ratio and cannot move the median, which is exactly
the property the per-company checks lacked.

Only FLOW metrics are eligible. A balance-sheet quarter is an INSTANT and its ratio is always ~1.
"""
import collections
import datetime
import json
import os
import statistics
import sys
import urllib.request

# Read LAZILY, not at import: `--self-test` needs no database, and a module-level lookup made the
# offline mode impossible to run — the script died on a missing env var before parsing its argv.
BASE = os.environ.get("BASE", "").rstrip("/")
KEY = os.environ.get("SRV", "")
UA = "muffin-market-verify/1.0"

FLOW = ["revenue", "net_income", "gross_profit", "operating_income", "operating_cash_flow"]

# Discrete quarters median ~1.0; year-to-date stacking gives last/first ~3.0 (a+b+c over a). The
# threshold sits in the gap, far enough above 1 that seasonality — which moves individual companies
# a long way but a median very little — cannot reach it.
CEILING = 2.0

# Below this the median is not a population statistic. Chosen so a handful of volatile companies
# cannot decide the outcome.
MIN_SAMPLES = 40


def ratio_of(qs: list) -> float | None:
    """Last quarter over first, by magnitude — the statistic the whole check rests on.

    Extracted so it can be exercised WITHOUT a database. A threshold nobody has watched fire is an
    assumption, and this one claims a specific number for contaminated data (~3.0) that is worth
    demonstrating rather than asserting.
    """
    if len(qs) < 3:
        return None
    qs = sorted(qs)
    first = abs(qs[0][1])
    if first == 0:
        return None
    return abs(qs[-1][1]) / first


def self_test() -> int:
    """Does the threshold actually separate discrete quarters from year-to-date ones?

    Runs the real statistic over synthetic series rather than over production, so the claim in the
    docstring — discrete ~1.0, cumulative ~3.0 — is checked rather than believed.
    """
    import datetime as _dt
    failures = 0

    def year(vals):
        return [(_dt.date(2025, 3 * (i + 1), 28), v) for i, v in enumerate(vals)]

    # Discrete: three independent quarters, including a lumpy one and a loss.
    discrete = [
        statistics.median([r for r in (
            ratio_of(year([100, 110, 105])),
            ratio_of(year([100, 180, 90])),     # a seasonal spike in the MIDDLE, not the end
            ratio_of(year([100, 90, -60])),     # a loss quarter, the Teads shape
            ratio_of(year([50, 55, 48])),
        ) if r is not None])
    ][0]
    if discrete > CEILING:
        print(f"  FAIL discrete quarters scored {discrete:.2f}, above the {CEILING} ceiling — the "
              "check would fire on clean data")
        failures += 1
    else:
        print(f"  ok   discrete quarters score {discrete:.2f} (under {CEILING})")

    # Year-to-date: the SAME underlying quarters, stored cumulatively.
    def ytd(a, b, c):
        return year([a, a + b, a + b + c])

    cumulative = statistics.median([r for r in (
        ratio_of(ytd(100, 110, 105)),
        ratio_of(ytd(100, 180, 90)),
        ratio_of(ytd(50, 55, 48)),
        ratio_of(ytd(100, 90, 80)),
    ) if r is not None])
    if cumulative <= CEILING:
        print(f"  FAIL cumulative quarters scored {cumulative:.2f}, at or under the {CEILING} "
              "ceiling — the check would NOT fire on the defect it exists for")
        failures += 1
    else:
        print(f"  ok   cumulative quarters score {cumulative:.2f} (over {CEILING})")

    print("  self-test passed" if failures == 0 else f"  {failures} self-test failure(s)")
    return 1 if failures else 0


def get(path: str):
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Accept-Profile": "market", "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b"[]")


def main() -> int:
    if not BASE or not KEY:
        print("::error::BASE and SRV must be set for the live check (use --self-test offline)")
        return 1
    metrics = ",".join(FLOW)

    # SAMPLED BY SECURITY, NOT BY RECENCY. The newest N metric rows are scattered across thousands
    # of securities, so a complete fiscal year almost never lands inside the page — tried, and it
    # compared zero years.
    recent = get(
        "security_metric?select=security_id&period_type=eq.quarter"
        f"&metric_code=in.({metrics})&order=fetched_at.desc&limit=1000"
    )
    ids: list[str] = []
    seen: set[str] = set()
    for r in recent:
        sid = r["security_id"]
        if sid not in seen:
            seen.add(sid)
            ids.append(sid)
        if len(ids) >= 60:
            break
    if not ids:
        print("::error::no quarterly flow metrics found at all — the derivation has produced nothing")
        return 1

    # An `in.()` filter is a URL and its size is a LENGTH budget: 60 UUIDs is ~2.4 KB, well under
    # the ~6.5 KB where the proxy answers a bare 502.
    rows = get(
        "security_metric?select=security_id,metric_code,as_of,value"
        f"&metric_code=in.({metrics})&security_id=in.({','.join(ids)})"
        "&period_type=eq.quarter&order=as_of&limit=6000"
    )

    # Group into fiscal years by calendar year of the period end. Exact fiscal boundaries do not
    # matter here: the statistic is about the SHAPE of a run of quarters, and a year boundary in the
    # wrong place adds noise to individual ratios without moving the median.
    groups = collections.defaultdict(list)
    for r in rows:
        try:
            as_of = datetime.date.fromisoformat(r["as_of"][:10])
            val = float(r["value"])
        except (TypeError, ValueError):
            continue
        groups[(r["security_id"], r["metric_code"], as_of.year)].append((as_of, val))

    ratios = [r for r in (ratio_of(qs) for qs in groups.values()) if r is not None]

    if len(ratios) < MIN_SAMPLES:
        # A check that measured almost nothing must not report success — the same rule the
        # derived-metric check learned when XBRL rows made its sample unresolvable.
        print(f"::error::quarter-shape check found only {len(ratios)} fiscal years with three or "
              f"more quarters (need {MIN_SAMPLES}) — too few to be a population statistic, which "
              "is itself a finding")
        return 1

    median = statistics.median(ratios)
    if median > CEILING:
        print(f"::error::the median last-quarter-to-first-quarter ratio is {median:.2f} across "
              f"{len(ratios)} fiscal years — discrete quarters sit near 1.0 and year-to-date "
              f"stacking near 3.0, so quarters are being stored cumulatively")
        return 1

    print(f"  ok   quarters are three months = median last/first ratio {median:.2f} across "
          f"{len(ratios)} fiscal years (contaminated would be ~3.0)")
    return 0


if __name__ == "__main__":
    # `--self-test` needs no database, so CI can run it on every PR while the live check runs only
    # against the deployment.
    sys.exit(self_test() if "--self-test" in sys.argv else main())
