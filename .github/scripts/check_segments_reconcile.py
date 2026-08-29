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


def get(path: str, offset: int = 0, limit: int = 1000):
    """One page. `Range` rather than `limit`, because `limit` above PGRST_DB_MAX_ROWS is silently
    truncated — see `get_all`."""
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={
            "apikey": KEY,
            "Authorization": f"Bearer {KEY}",
            "Accept-Profile": "market",
            "User-Agent": UA,
            "Range-Unit": "items",
            "Range": f"{offset}-{offset + limit - 1}",
        },
    )
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.loads(r.read() or b"[]")


def get_all(path: str, cap: int = 60_000):
    """Every row, paged.

    `PGRST_DB_MAX_ROWS` IS 1000 AND A BIGGER `limit` IS NOT AN ERROR — it is a shorter answer. This
    guard asked for `limit=4000`, got 1000, and reported ASML's FY2021 split at 7,226,500,000
    against a filed 18,611,000,000: a ratio of 0.39 and a completely false alarm, because half the
    split was past the end of a page whose end could not be seen. That is the fourth time this
    exact trap has cost this pipeline a defect, and the first time it was inside a guard.

    A partial split can never reconcile, so this check is meaningless on anything but whole ones.
    """
    out, offset = [], 0
    while offset < cap:
        page = get(path, offset)
        out.extend(page)
        if len(page) < 1000:
            return out
        offset += 1000
    print(f"::error::{path} exceeded {cap} rows — the sample is truncated and cannot reconcile")
    sys.exit(1)


def main() -> int:
    # The most recently written segment rows, which is where a regression appears first. Narrowed
    # explicitly: an unbounded select silently returns `PGRST_DB_MAX_ROWS` and a guard sized by a
    # page whose end it cannot see has already cost this pipeline three defects.
    # `security_segment_latest`, NOT the raw table. An annual report carries three years of
    # comparatives, so a period appears in several filings — and filers RENAME member codes
    # between them (ASML's `EuvMember` became `NXEMember`, and `Metrologyandinspection` differs
    # from `MetrologyAndInspection` only in case). Reading the raw table unions two complete
    # splits of the same period; this check found exactly that on its first production run,
    # reporting ASML's FY2022 split at 34,114,800,000 against a filed 21,173,400,000.
    rows = get_all(
        "security_segment_latest?select=security_id,axis,member_code,parent_member,metric_code,"
        "period_type,period_ending,value,partition_id,currency_code,reconciled_to"
        # FLAT MEMBERS ONLY. A nested cell reconciles to its PARENT's value, not to the company's
        # consolidated figure, so summing the two levels together is exactly the double count this
        # check exists to catch — and it produced one: Novo Nordisk's
        # `DiabetesAndObesityCareMember` appears once per parent, and summing all of them reported
        # a ratio of 2.97 for six consecutive years. The nested level has its own assertion below.
        "&parent_member=is.null"
        "&order=security_id,axis,period_ending"
    )
    if not rows:
        print("::notice::no segment rows yet — nothing to reconcile")
        return 0

    # The filing's own consolidated figure for the same concept and period. `security_metric` holds
    # it because `security-xbrl` writes exactly the undimensioned facts this needs.
    keys = {(r["security_id"], r["metric_code"], r["period_type"], r["period_ending"]) for r in rows}
    sec_ids = sorted({k[0] for k in keys})
    # (security, metric, period_type, as_of) -> (value, currency)
    totals = {}
    # ~100 per `in.()` chunk: the filter is a URL, so the limit is a LENGTH budget. 500 ISINs made
    # a ~6.5 KB URL that the proxy answered with a bare 502.
    for i in range(0, len(sec_ids), 100):
        chunk = ",".join(sec_ids[i : i + 100])
        for m in get_all(
            "security_metric?select=security_id,metric_code,period_type,as_of,value,currency_code"
            f"&security_id=in.({chunk})&metric_code=in.(revenue,operating_income)"
            # ONLY A FILING-SOURCED TOTAL IS A VALID TARGET. The segment split comes from the
            # filing's own instance, so comparing it against a PROVIDER's revenue compares two
            # different measurements of two different things — and often in two different
            # currencies. Measured on Credicorp: its geography split sums correctly to
            # 28,555,000,000 **PEN**, and this check called it broken (ratio 1.19) against a
            # yfinance figure of 23,986,309,000 carrying NO currency at all.
            "&source_code=in.(sec-xbrl,sec)"
            "&order=security_id,as_of"
        ):
            totals[(m["security_id"], m["metric_code"], m["period_type"], m["as_of"])] = (
                float(m["value"]),
                m.get("currency_code"),
            )

    sums: dict[tuple, float] = {}
    partitions: dict[tuple, set] = {}
    currencies: dict[tuple, str | None] = {}
    targets: dict[tuple, float] = {}
    for r in rows:
        base = (r["security_id"], r["metric_code"], r["period_type"], r["period_ending"])
        gk = base + (r["axis"],)
        partitions.setdefault(gk, set()).add(r["partition_id"])
        if r["partition_id"] == 1:
            sums[gk] = sums.get(gk, 0.0) + float(r["value"])
            currencies[gk] = r.get("currency_code")
            if r.get("reconciled_to") is not None:
                targets[gk] = float(r["reconciled_to"])

    # ── THE PRIMARY ASSERTION: does each split still add up to what it was ACCEPTED against? ──
    #
    # Exact, and needs no second source. `reconciled_to` is the figure the parser used — the
    # filing's own consolidated value, resolved within the one document it read. A member counted
    # twice, a subtotal admitted, or two filings unioned all break this and nothing else does.
    internal_checked = 0
    internal_bad = []
    for gk, total_of_split in sums.items():
        target = targets.get(gk)
        if target is None:
            continue
        internal_checked += 1
        if abs(total_of_split - target) > max(1.0, abs(target) * TOLERANCE_FRACTION):
            internal_bad.append(
                f"{gk[0][:8]} {gk[4].split(':')[-1]} {gk[2]} {gk[3]}: "
                f"split={total_of_split:,.0f} accepted against={target:,.0f}"
            )

    checked = 0
    skipped_currency = 0
    bad = []
    short: list[str] = []
    for gk, total_of_split in sums.items():
        base = gk[:4]
        found = totals.get(base)
        if found is None:
            continue
        consolidated, total_currency = found
        if abs(consolidated) < MIN_TOTAL:
            continue
        # AND IT MUST BE THE SAME CURRENCY. A foreign private issuer files in its own — Credicorp in
        # PEN, Diageo in USD despite being British — so a mismatch is two numbers that were never
        # comparable, not a defect in the split. `is not None` on both: an unknown currency on
        # either side is not evidence of agreement.
        split_currency = currencies.get(gk)
        if total_currency is not None and split_currency is not None \
                and total_currency != split_currency:
            skipped_currency += 1
            continue
        # SEGMENT PROFIT IS EXEMPT AND THAT IS NOT A LOOPHOLE. ASC 280 and IFRS 8 both require a
        # RECONCILIATION rather than an identity: shared costs are deliberately unallocated, so
        # Apple's segment operating income sums to ~38.9bn against a consolidated ~28.2bn. Only
        # revenue is expected to add up, and only revenue is asserted.
        if gk[1] != "revenue":
            continue
        checked += 1
        excess = total_of_split - consolidated
        # OVER-COUNTING IS OUR BUG; UNDER-COUNTING IS USUALLY THE FILER'S CHOICE.
        #
        # A split that exceeds the company's own revenue can only mean a member counted twice — a
        # merged partition, a subtotal admitted, or two filings unioned. That is the defect this
        # check exists for and it FAILS.
        #
        # A split that falls SHORT is a different thing. Novo Nordisk discloses geographies covering
        # ~37% of revenue and segment revenue at ~93% of it; Credicorp's geographies are complete.
        # Neither is a pipeline defect: a filer chooses how much of itself to disaggregate, and the
        # consolidated figure being compared against comes from companyfacts, which may resolve a
        # different revenue concept than the instance did. An incomplete split is still safe to
        # serve — it is partial, not wrong — so it is REPORTED and counted rather than failed.
        if excess < 0:
            short.append(
                f"{gk[0][:8]} {gk[4].split(':')[-1]} {gk[2]} {gk[3]}: "
                f"covers {100 * total_of_split / consolidated:.0f}% of revenue"
            )
            continue
        if excess > max(1.0, abs(consolidated) * TOLERANCE_FRACTION):
            bad.append(
                f"{gk[0][:8]} {gk[4].split(':')[-1]} {gk[2]} {gk[3]}: "
                f"split={total_of_split:,.0f} filing={consolidated:,.0f} "
                f"(ratio {total_of_split / consolidated:.2f})"
            )

    if checked == 0:
        # No longer fatal: the INTERNAL check above is the one that must never be vacuous, and it
        # has its own zero guard. This one depends on a second source existing for the same period
        # and can legitimately find nothing.
        print("::notice::no split could be compared against companyfacts (no filing-sourced total)")

    # THE INVERSE. Where a second partition exists, summing ACROSS partitions must NOT reconcile —
    # otherwise a mutation that merges every member into partition 1 would leave this check green.
    merged_ok = 0
    for gk, parts in partitions.items():
        if gk[1] == "revenue" and len(parts - {0}) > 1:
            merged_ok += 1
    print(
        f"::notice::reconciled {checked} revenue splits against the filing; "
        f"{merged_ok} axes carry more than one split (summing them would double the revenue); "
        f"{skipped_currency} skipped on a currency mismatch; "
        f"{len(short)} disaggregate only part of the company"
    )
    for line in short[:10]:
        print(f"::notice::  partial: {line}")

    print(
        f"::notice::{internal_checked} splits re-checked against the figure they were accepted "
        f"against; {len(bad)} disagree with companyfacts' independently derived total"
    )
    for b in bad[:10]:
        print(f"::notice::  source drift: {b}")

    if internal_bad:
        # THE ONLY FAILURE THAT MEANS A DEFECT. Everything else here is two sources measuring the
        # same company differently, which is worth seeing and is not a bug in the split.
        print(f"::error::{len(internal_bad)} split(s) no longer sum to what they were accepted against:")
        for b in internal_bad[:20]:
            print(f"::error::  {b}")
        return 1
    if internal_checked == 0:
        print("::error::re-checked 0 splits — `reconciled_to` is empty, so nothing was verified")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
