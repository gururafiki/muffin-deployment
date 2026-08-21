"""A quarterly figure must be a quarter of a year, not a slice of one.

WHY THIS EXISTS. `security-xbrl` classified a fact as quarterly from its `fp` label and bounded the
duration on one side only. XBRL's Q2 and Q3 duration facts are frequently YEAR-TO-DATE — six and
nine months — and still carry `fp: "Q2"`, so the nine-month figure was dropped and the six-month
one was kept. Measured in production:

    AAPL revenue  quarter  2026-03-28   254,940,000,000
    AAPL revenue  annual   2025-09-27   416,161,000,000

61% of a full year inside one quarter. The quarterly chart spiked every Q2, a TTM built on it would
have been badly wrong, and NOTHING in any row count or resource response showed it — the resource
reported success throughout.

So the check is a RATIO, not a count: a flow metric's quarter, compared against its own annual
figure for the surrounding year. Four clean quarters average 25% of a year; a genuinely lumpy
business (a retailer's Christmas quarter, a miner's shipment timing) can reach 40%. Past that, the
period is not a quarter.

Only FLOW metrics are eligible. A balance-sheet quarter is an INSTANT — total assets at quarter-end
is ~100% of total assets at year-end, and comparing them would flag every security.
"""
import collections
import json
import os
import sys
import urllib.request

BASE = os.environ["BASE"].rstrip("/")
KEY = os.environ["SRV"]
UA = "muffin-market-verify/1.0"

# Flows only. `total_assets`, `total_equity`, `cash_and_equivalents` and the debt metrics are
# instants and are deliberately absent.
FLOW = ["revenue", "net_income", "gross_profit", "operating_income", "operating_cash_flow"]

# Four even quarters are 25%. A lumpy but legitimate one reaches 40%; a six-month YTD figure is
# ~50-60%, which is what this exists to catch. The gap between them is the whole margin.
CEILING = 0.45


def get(path: str):
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Accept-Profile": "market", "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b"[]")


def main() -> int:
    metrics = ",".join(FLOW)
    rows = get(
        "security_metric?select=security_id,metric_code,period_type,as_of,value"
        f"&metric_code=in.({metrics})&value=gt.0&order=fetched_at.desc&limit=1000"
    )
    if not rows:
        print("::error::no flow metrics found at all — the derivation has produced nothing")
        return 1

    annual = {}
    quarters = collections.defaultdict(list)
    for r in rows:
        key = (r["security_id"], r["metric_code"])
        if r["period_type"] == "annual":
            # Keep the largest annual figure per (security, metric) as the yardstick. Using the
            # newest instead would compare a quarter against a year it does not belong to.
            annual[key] = max(annual.get(key, 0.0), float(r["value"]))
        elif r["period_type"] == "quarter":
            quarters[key].append((r["as_of"], float(r["value"])))

    checked = 0
    bad = []
    for key, qs in quarters.items():
        year = annual.get(key)
        if not year:
            continue
        for as_of, val in qs:
            checked += 1
            share = val / year
            if share > CEILING:
                bad.append(f"{key[1]} for {key[0][:8]} {as_of}: {val:,.0f} is "
                           f"{share:.0%} of the annual {year:,.0f}")

    if checked == 0:
        # A check that compared nothing must not report success — the same rule the derived-metric
        # check learned when XBRL rows made its sample unresolvable.
        print("::error::quarter-share check compared 0 values — no security had both a quarterly "
              "and an annual figure for the same flow metric, which is itself a finding")
        return 1

    if bad:
        print(f"::error::{len(bad)} quarterly figures exceed {CEILING:.0%} of their annual value "
              f"— a year-to-date fact is being stored as a quarter")
        for b in bad[:10]:
            print(f"::error::  {b}")
        return 1

    print(f"  ok   quarterly figures are quarters = {checked} compared, none above {CEILING:.0%}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
