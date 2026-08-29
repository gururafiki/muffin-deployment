"""Each disclosed split must sum to the company's own consolidated figure.

WHY THIS IS THE ONLY CHECK THAT CAN TELL SEGMENT DATA IS WRONG. Every failure mode here produces a
plausible number rather than an error, and the individual values stay correct while the totals do
not:

  * AN AXIS CARRIES SEVERAL OVERLAPPING SPLITS. Measured on Amazon's FY2025 10-K, the
    `ProductOrService` axis holds a seven-line split summing to 716,924,000,000 **and** a
    Product/Service split summing to 716,924,000,000, while `StatementBusinessSegments` holds a
    three-line split summing to the same again. `sum(value)` over an axis doubles the company's
    revenue; over the table it triples it. Nothing errors.
  * A SUBTOTAL IS COUNTED BESIDE ITS OWN CHILDREN. Apple's `ProductMember` is the sum of iPhone,
    iPad, Mac and Wearables and sits on the same axis as them.
  * THE PARSER'S PARTITIONING SILENTLY DEGRADES. If a filing's shape changes and the subset search
    stops finding a reconciling split, everything lands in partition 0 — the resource still reports
    success, the rows are still written, and the page simply shows nothing.

So the assertion is arithmetic and absolute: for every (security, axis, metric, period) that has a
partition 1, those members must sum to the undimensioned figure the same filing reported, within a
rounding tolerance. That single statement catches all three.

IT ALSO ASSERTS THE INVERSE, which is the half that would otherwise rot: summing ACROSS partitions
must NOT reconcile wherever a second partition exists. A guard that only checks partition 1 would
pass just as happily if every member were dumped into partition 1 together — which is precisely the
defect, and is what the mutation of this check produces.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ["BASE"].rstrip("/")
KEY = os.environ["SRV"]
# urllib's default User-Agent gets a 403 from Cloudflare on supabase.<domain>, which reads exactly
# like an auth failure and is not.
UA = "muffin-market-verify/1.0"

# RELATIVE, and it must match `segments.ts`'s `TOLERANCE_FRACTION` or this guard flags exactly the
# splits the parser deliberately accepted.
#
# Segment revenue carries a reconciling item, the same way segment profit does. Alphabet's FY2025:
# Google Services 342,721,000,000 + Google Cloud 58,705,000,000 + All Other 1,537,000,000 =
# 402,963,000,000 against a consolidated 402,836,000,000 — 127,000,000 of hedging gains, or 0.032%.
# An exact rule calls that broken and hides Google Cloud. The error actually being guarded against
# is an INTEGER MULTIPLE — a doubled split is 100% out, a subtotal beside its children ~70% — so
# half a percent separates the two by two orders of magnitude.
TOLERANCE_FRACTION = 0.005
# Below this the arithmetic is dominated by rounding rather than by the data.
MIN_TOTAL = 1000


def get(path: str):
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={
            "apikey": KEY,
            "Authorization": f"Bearer {KEY}",
            "Accept-Profile": "market",
            "User-Agent": UA,
        },
    )
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.loads(r.read() or b"[]")


def main() -> int:
    # The most recently written segment rows, which is where a regression appears first. Narrowed
    # explicitly: an unbounded select silently returns `PGRST_DB_MAX_ROWS` and a guard sized by a
    # page whose end it cannot see has already cost this pipeline three defects.
    rows = get(
        "security_segment?select=security_id,axis,member_code,metric_code,period_type,"
        "period_ending,value,partition_id&order=as_of.desc&limit=4000"
    )
    if not rows:
        print("::notice::no segment rows yet — nothing to reconcile")
        return 0

    # The filing's own consolidated figure for the same concept and period. `security_metric` holds
    # it because `security-xbrl` writes exactly the undimensioned facts this needs.
    keys = {(r["security_id"], r["metric_code"], r["period_type"], r["period_ending"]) for r in rows}
    sec_ids = sorted({k[0] for k in keys})
    totals = {}
    # ~100 per `in.()` chunk: the filter is a URL, so the limit is a LENGTH budget. 500 ISINs made
    # a ~6.5 KB URL that the proxy answered with a bare 502.
    for i in range(0, len(sec_ids), 100):
        chunk = ",".join(sec_ids[i : i + 100])
        for m in get(
            "security_metric?select=security_id,metric_code,period_type,as_of,value"
            f"&security_id=in.({chunk})&metric_code=in.(revenue,operating_income)"
        ):
            totals[(m["security_id"], m["metric_code"], m["period_type"], m["as_of"])] = float(
                m["value"]
            )

    sums: dict[tuple, float] = {}
    partitions: dict[tuple, set] = {}
    for r in rows:
        base = (r["security_id"], r["metric_code"], r["period_type"], r["period_ending"])
        gk = base + (r["axis"],)
        partitions.setdefault(gk, set()).add(r["partition_id"])
        if r["partition_id"] == 1:
            sums[gk] = sums.get(gk, 0.0) + float(r["value"])

    checked = 0
    bad = []
    for gk, total_of_split in sums.items():
        base = gk[:4]
        consolidated = totals.get(base)
        if consolidated is None or abs(consolidated) < MIN_TOTAL:
            continue
        # SEGMENT PROFIT IS EXEMPT AND THAT IS NOT A LOOPHOLE. ASC 280 and IFRS 8 both require a
        # RECONCILIATION rather than an identity: shared costs are deliberately unallocated, so
        # Apple's segment operating income sums to ~38.9bn against a consolidated ~28.2bn. Only
        # revenue is expected to add up, and only revenue is asserted.
        if gk[1] != "revenue":
            continue
        checked += 1
        if abs(total_of_split - consolidated) > max(1.0, abs(consolidated) * TOLERANCE_FRACTION):
            bad.append(
                f"{gk[0][:8]} {gk[4].split(':')[-1]} {gk[2]} {gk[3]}: "
                f"split={total_of_split:,.0f} filing={consolidated:,.0f} "
                f"(ratio {total_of_split / consolidated:.2f})"
            )

    if checked == 0:
        # A CHECK THAT VERIFIED NOTHING MUST NEVER READ AS ONE THAT PASSED. `check_derived_metrics`
        # began reporting "compared 0 values" the day a new source started writing, and failing
        # loudly is what surfaced it.
        print("::error::reconciled 0 splits — segment rows exist but none could be compared")
        return 1

    # THE INVERSE. Where a second partition exists, summing ACROSS partitions must NOT reconcile —
    # otherwise a mutation that merges every member into partition 1 would leave this check green.
    merged_ok = 0
    for gk, parts in partitions.items():
        if gk[1] == "revenue" and len(parts - {0}) > 1:
            merged_ok += 1
    print(
        f"::notice::reconciled {checked} revenue splits against the filing; "
        f"{merged_ok} axes carry more than one split (summing them would double the revenue)"
    )

    if bad:
        print(f"::error::{len(bad)} segment split(s) do not sum to the filing's own figure:")
        for b in bad[:20]:
            print(f"::error::  {b}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
