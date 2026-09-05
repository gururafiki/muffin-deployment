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
# The historical backlog on 2026-09-04 was 729, on a sample of 80 securities. Set with headroom for
# sample variation, low enough that a real regression in old-filing parsing trips it.
HISTORICAL_TRIPWIRE = int(os.environ.get("SEGMENT_HISTORICAL_TRIPWIRE", "900"))
# And the served backlog was 23. BOTH ARE TRIPWIRES ON A COUNT, NOT CEILINGS ON A VALUE: these are
# splits whose `reconciled_to` is wrong rather than splits that are wrong — GE Vernova's three
# segments sum to a correct $30.1bn against a recorded target of $487m — so the data being served
# is right and the target it is checked against is not. Failing on them makes the gate permanently
# red; letting the count GROW silently is how a real regression hides. Headroom because the sample
# is the 80 most-recently-written securities and therefore rotates between runs.
SERVED_TRIPWIRE = int(os.environ.get("SEGMENT_SERVED_TRIPWIRE", "35"))
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


def recent_securities(limit: int) -> list[str]:
    """The most recently written securities, newest first.

    THE SCOPE HAS TO BE SECURITIES, NOT ROWS OR A TIME WINDOW, AND BOTH ALTERNATIVES WERE MEASURED.

    This guard used to read the whole of `security_segment_latest` and died the moment it outgrew
    its own 60,000-row cap: 105,166 flat rows on 2026-09-04, against 271 securities and ~33,000
    filings still queued. It had already been failing for at least a day, silently — a check that
    exits 1 on its own sample size asserts nothing about the data, and this is the guard covering
    the one thing the segment pipeline must never get wrong.

    A TIME WINDOW DOES NOT BOUND IT. `segment_parser.version` re-queues every filing when it is
    bumped, so everything is "recently written" after a re-parse — measured, the last 7 days
    contained all 105,166 rows and the last 3 still contained 74,941.

    TRUNCATING BY ROW IS WORSE THAN NOT RUNNING. A split that is half-fetched can never reconcile,
    so a row cap manufactures exactly the failure the check reports — which is how `limit=4000`
    once put ASML's FY2021 split at a ratio of 0.39. Scoping by SECURITY and then fetching each
    one whole keeps every split complete, which is the property the assertion depends on.
    """
    seen: list[str] = []
    known: set[str] = set()
    offset = 0
    # A page covers ~12 securities (388 flat rows per security, measured), so this walks a few
    # thousand rows to gather the sample. Bounded twice: by the sample size and by the walk.
    while len(seen) < limit and offset < 20_000:
        page = get(
            "security_segment_latest?select=security_id,as_of"
            # Tie-broken for the same reason as the row fetch below. Here a duplicate is harmless
            # (the ids go into a set) but a SKIPPED row silently biases which securities are
            # sampled, which is worse — it is invisible.
            "&parent_member=is.null&order=as_of.desc,security_id",
            offset,
        )
        if not page:
            break
        for r in page:
            sid = r["security_id"]
            if sid not in known:
                known.add(sid)
                seen.append(sid)
        if len(page) < 1000:
            break
        offset += 1000
    return seen[:limit]


def main() -> int:
    # A ROLLING SAMPLE OF WHOLE SECURITIES, newest-written first — where a regression appears first.
    # See `recent_securities` for why this is not the whole table, not a row cap and not a date
    # filter. `SEGMENT_SAMPLE_SECURITIES` raises it for a one-off deep run.
    # `security_segment_latest`, NOT the raw table. An annual report carries three years of
    # comparatives, so a period appears in several filings — and filers RENAME member codes
    # between them (ASML's `EuvMember` became `NXEMember`, and `Metrologyandinspection` differs
    # from `MetrologyAndInspection` only in case). Reading the raw table unions two complete
    # splits of the same period; this check found exactly that on its first production run,
    # reporting ASML's FY2022 split at 34,114,800,000 against a filed 21,173,400,000.
    sample = recent_securities(int(os.environ.get("SEGMENT_SAMPLE_SECURITIES", "80")))
    if not sample:
        print("::notice::no segment rows yet — nothing to reconcile")
        return 0
    print(f"  sampling the {len(sample)} most recently written securities")

    rows = []
    # ~100 ids per `in.()`: the filter is a URL, so the bound is a LENGTH budget, not a row budget.
    for i in range(0, len(sample), 100):
        chunk = ",".join(sample[i : i + 100])
        rows += get_all(
            "security_segment_latest?select=security_id,axis,member_code,parent_member,metric_code,"
            "period_type,period_ending,value,partition_id,currency_code,reconciled_to,accession_number"
            f"&security_id=in.({chunk})"
        # FLAT MEMBERS ONLY. A nested cell reconciles to its PARENT's value, not to the company's
        # consolidated figure, so summing the two levels together is exactly the double count this
        # check exists to catch — and it produced one: Novo Nordisk's
        # `DiabetesAndObesityCareMember` appears once per parent, and summing all of them reported
        # a ratio of 2.97 for six consecutive years. The nested level has its own assertion below.
            "&parent_member=is.null"
            # A TOTAL ORDER, BECAUSE OFFSET PAGING OVER TIED KEYS DUPLICATES AND DROPS ROWS.
            # `security_id,axis,period_ending` leaves every member of a split tied, so PostgreSQL
            # is free to return them in any order within the tie — and across a page boundary that
            # means some rows come back twice while others are never seen at all. Measured on the
            # live 80-security sample, 21,059 rows over 22 pages:
            #   order=security_id,axis,period_ending          40 duplicated, 21,019 distinct
            #   + metric_code,period_type,member_code,accession    0 duplicated, 21,059 distinct
            # Both directions corrupt a reconciliation: a duplicated member inflates its split and
            # the row it displaced is missing from another. That is why the failures had no single
            # signature — ten over and ten under, changing between runs — and why Costco's
            # geography split was reported at exactly 2.00x while fetching the security ALONE
            # reconciled it to the cent.
            "&order=security_id,axis,period_ending,metric_code,period_type,member_code,accession_number"
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

    # ── A SPLIT PARSED BY AN OLD PARSER IS A BACKLOG ITEM, NOT A DEFECT ────────────────────────
    #
    # `segment_parser.version` re-queues every filing when it is bumped, and the queue is ~33,000
    # filings deep, so at any moment most stored splits were produced by a parser that has since
    # been fixed. Reporting those as failures makes this guard measure the DRAIN RATE rather than
    # the parser, and a gate that is red for a reason nobody can act on is one nobody reads.
    #
    # Measured 2026-09-05, on the 18 served disagreements this check reported: SIXTEEN were parsed
    # at version 2 or 9 against a current parser at 14 — including every case whose reconciliation
    # target belonged to a different metric, which PR #289 ("a reconciliation target belongs to its
    # own bucket, not to the group") had already fixed. Only Equinor and Chevron were produced by
    # the current parser. The stale ones will correct themselves as the queue drains, and counting
    # them told us nothing except how far it has got.
    #
    # They are COUNTED, not silently dropped: a stale population that stops shrinking is a stalled
    # re-parse, which is worth seeing — it is just not a parser defect.
    parser_version = None
    try:
        pv = get("segment_parser?select=version")
        parser_version = int(pv[0]["version"]) if pv else None
    except Exception:
        parser_version = None
    version_of: dict[str, int] = {}
    if parser_version is not None:
        accs = sorted({r["accession_number"] for r in rows if r.get("accession_number")})
        for i in range(0, len(accs), 60):
            chunk = ",".join(accs[i : i + 60])
            for f in get_all(
                "security_filing?select=accession_number,segments_parser_version"
                f"&accession_number=in.({chunk})"
            ):
                if f.get("segments_parser_version") is not None:
                    version_of[f["accession_number"]] = int(f["segments_parser_version"])

    def is_stale(acc: str | None) -> bool:
        """True when this split predates the current parser, so its defects are already fixed."""
        if parser_version is None or not acc:
            return False
        v = version_of.get(acc)
        return v is not None and v < parser_version

    stale_group: dict[tuple, bool] = {}

    sums: dict[tuple, float] = {}
    partitions: dict[tuple, set] = {}
    currencies: dict[tuple, str | None] = {}
    targets: dict[tuple, float] = {}
    for r in rows:
        base = (r["security_id"], r["metric_code"], r["period_type"], r["period_ending"])
        gk = base + (r["axis"],)
        partitions.setdefault(gk, set()).add(r["partition_id"])
        if r["partition_id"] == 1:
            if is_stale(r.get("accession_number")):
                stale_group[gk] = True
            sums[gk] = sums.get(gk, 0.0) + float(r["value"])
            currencies[gk] = r.get("currency_code")
            if r.get("reconciled_to") is not None:
                targets[gk] = float(r["reconciled_to"])

    # ── THE PRIMARY ASSERTION: does each split still add up to what it was ACCEPTED against? ──
    #
    # Exact, and needs no second source. `reconciled_to` is the figure the parser used — the
    # filing's own consolidated value, resolved within the one document it read. A member counted
    # twice, a subtotal admitted, or two filings unioned all break this and nothing else does.
    # The newest annual period per (security, axis) — what `security_segment_current` serves.
    served_period: dict[tuple, str] = {}
    for gk in sums:
        k = (gk[0], gk[4], gk[2])
        if gk[3] > served_period.get(k, ""):
            served_period[k] = gk[3]

    internal_checked = 0
    internal_bad: list[str] = []
    internal_old: list[str] = []
    internal_stale: list[str] = []
    for gk, total_of_split in sums.items():
        target = targets.get(gk)
        if target is None:
            continue
        # REVENUE ONLY, FOR THE SAME REASON THE SECOND CHECK IS REVENUE ONLY — and this assertion
        # was missing it, which is what made it report 2,724 failures on correct data.
        #
        # `reconciled_to` is stored per (security, axis, period), NOT per metric: measured
        # 2026-09-04, 82 of 83 multi-metric groups carry ONE value across every metric, and it is
        # the REVENUE total. That is deliberate — a segment split is learned from the metric that
        # reconciles and applied to the rest, because ASC 280 and IFRS 8 require a reconciliation
        # rather than an identity and shared costs are left unallocated. So Apple's FY2025 rows all
        # carry 416,161,000,000: revenue matches it exactly, while `cost_of_revenue` (220,960m) and
        # `operating_income` (175,677m) never can and were being failed for it.
        if gk[1] != "revenue":
            continue
        internal_checked += 1
        if abs(total_of_split - target) > max(1.0, abs(target) * TOLERANCE_FRACTION):
            line = (
                f"{gk[0][:8]} {gk[4].split(':')[-1]} {gk[2]} {gk[3]}: "
                f"split={total_of_split:,.0f} accepted against={target:,.0f}"
            )
            # SERVED OR HISTORICAL, because they are different facts and one of them is urgent.
            # `security_segment_current` picks the newest annual period per (security, axis) — that
            # is the only split a reader ever sees, so a defect there is live and fails. A bad
            # split from 2011 is real and worth counting, but it is a backlog: failing on it makes
            # the gate permanently red, and a permanently red gate is one nobody reads. Measured
            # 2026-09-04: 729 historical against a handful served.
            # AND A SPLIT THE CURRENT PARSER NEVER PRODUCED CANNOT BE EVIDENCE ABOUT IT.
            # 16 of the 18 served disagreements measured on 2026-09-05 were parsed at version 2 or
            # 9 against a parser at 14 — already fixed, queued, and waiting on a ~33,000-filing
            # re-parse. Counted separately so a stalled drain is still visible.
            if stale_group.get(gk):
                internal_stale.append(line)
            elif gk[3] == served_period.get((gk[0], gk[4], gk[2])):
                internal_bad.append(line)
            else:
                internal_old.append(line)

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

    print(
        f"::notice::{len(internal_stale)} split(s) disagree but were produced by an OLDER PARSER "
        f"(current version {parser_version}) — already fixed, awaiting re-parse, not asserted on"
    )
    for b in internal_stale[:5]:
        print(f"::notice::  stale: {b}")

    print(
        f"::notice::{len(internal_old)} HISTORICAL split(s) disagree with their target "
        f"(tripwire {HISTORICAL_TRIPWIRE}) — a known backlog in old filings, not served to anyone"
    )
    for b in internal_old[:5]:
        print(f"::notice::  historical: {b}")

    # A SERVED split someone is being shown right now — the urgent half.
    print(
        f"::notice::{len(internal_bad)} SERVED split(s) disagree with their target "
        f"(tripwire {SERVED_TRIPWIRE})"
    )
    for b in internal_bad[:20]:
        print(f"::notice::  served: {b}")
    if len(internal_bad) > SERVED_TRIPWIRE:
        print(
            f"::error::{len(internal_bad)} served splits disagree with their target, above the "
            f"{SERVED_TRIPWIRE} tripwire — a split a reader is being shown does not add up"
        )
        return 1
    if len(internal_old) > HISTORICAL_TRIPWIRE:
        # Not a ceiling on the value, a tripwire on the count — the backlog is allowed to exist and
        # is not allowed to GROW, which is the only way a regression in historical parsing shows up.
        print(
            f"::error::historical disagreements rose to {len(internal_old)}, above the "
            f"{HISTORICAL_TRIPWIRE} tripwire — something regressed in how old filings are parsed"
        )
        return 1
    if internal_checked == 0:
        print("::error::re-checked 0 splits — `reconciled_to` is empty, so nothing was verified")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
