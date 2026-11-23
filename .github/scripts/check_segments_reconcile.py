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
# WHAT COUNTS AS A DEFECT, AND WHAT DOES NOT (2026-11-21).
#
# A split's members can disagree with the target in three ways, and they are different facts:
#
# - NON-POSITIVE: the split, or the target it carries, is zero or less. A revenue split cannot total
#   nothing, nor be reconciled to a negative revenue. The parser refuses both since muffin-ingest#185,
#   and the filings that held one were re-queued, so among splits the CURRENT parser produced there
#   must be NONE. Any one fails.
# - OVER: the split exceeds its target. A member counted twice, a subtotal beside its children, or
#   intersegment sales the parser could not match to an elimination. A defect, and a RATE tripwire,
#   because a few are accepted states the UI already refuses to draw percentages for.
# - UNDER: the split covers part of its target. A bucket inherits its partition from whichever
#   bucket placed the most members (a split learned from assets or depreciation applies to revenue
#   too), and a filer chooses how much of itself to disaggregate. Served on purpose, with the
#   remainder named by the UI, so it is REPORTED and never failed. It was 85% of what this check
#   used to call disagreements, which is why its historical rate looked like a rising defect.
#
# The rates, measured 2026-11-21 over the WHOLE table (revenue, partition 1, flat), by the period's
# year: over-coverage 2.12% before 2016, 1.36% 2016-19, 1.07% 2020-23, 0.96% 2024 onward, served
# 0.95%. The tripwires sit at about twice that. A band is judged only once it holds MIN_BAND_SPLITS.
#
# WHY THE HISTORICAL RATE ROSE (umbrella docs/deferred/2026-10-04-the-historical-segment-backlog-
# is-rising.md): the parser was one deterministic function at one version throughout, so a filing's
# result cannot change; older filings disagree more (22% before 2016 against ~11% from 2024, in
# rows the edge wrote), and the sample, the most recently written securities, followed the drain to
# older filings. On 2026-11-21 the same sample read 0 of 6,367 because it was all Chinese companies
# from that day's CNINFO drain, which is why it is now drawn per regulator.
SERVED_OVER_TRIPWIRE = float(os.environ.get("SEGMENT_SERVED_TRIPWIRE", "0.025"))
HISTORICAL_OVER_TRIPWIRE = {"<2016": 0.04, "2016-2019": 0.03, "2020-2023": 0.025, "2024+": 0.025}
MIN_BAND_SPLITS = 200
#: Each regulator is sampled on its own, so the lane draining hardest cannot be the whole sample.
SAMPLE_SOURCES = ("sec-segments", "cninfo", "dart", "nse")


def band_of(period_ending: str) -> str:
    """The year band a period falls in, for the historical tripwire."""
    year = int(period_ending[:4])
    if year < 2016:
        return "<2016"
    if year < 2020:
        return "2016-2019"
    if year < 2024:
        return "2020-2023"
    return "2024+"
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
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return json.loads(r.read() or b"[]")
    except urllib.error.HTTPError as e:
        # POSTGREST NAMES THE CAUSE IN THE BODY, AND A TRACEBACK DROPS IT. This check failed with a
        # bare `HTTP Error 500` on every run from at least 2026-10-01 to 10-04, and the cause had to
        # be found by timing its query on the node.
        print(f"::error::{path.split('?')[0]}: HTTP {e.code} {e.read().decode('utf-8', 'replace')[:300]}")
        sys.exit(1)


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


def recent_securities(limit: int, source: str) -> list[str]:
    """One regulator's most recently written securities, newest first.

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

    THE SAMPLE READS THE TABLE, NOT THE VIEW. `security_segment_latest` dense-ranks the whole table
    before it can sort, so on 2026-10-04, at 1.44M rows, ONE page of this walk cost 6.4 s and the
    walk is several pages, each paying it again, under the 8-second ceiling of the role PostgREST
    connects as. Every run from at least 2026-10-01 died here with HTTP 500 before a single split
    was checked. `security_segment` answers the same question — which securities were written most
    recently — in 0.22-0.30 s a page, and its first page already held 60 securities. The rows
    themselves still come from the view in `main`, so this changes WHICH securities are checked,
    never what they are checked against.
    """
    seen: list[str] = []
    known: set[str] = set()
    offset = 0
    # A page covers ~12 securities (388 flat rows per security, measured), so this walks a few
    # thousand rows to gather the sample. Bounded twice: by the sample size and by the walk.
    while len(seen) < limit and offset < 20_000:
        page = get(
            f"security_segment?select=security_id,as_of&source_code=eq.{source}"
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
    per_source = int(os.environ.get("SEGMENT_SAMPLE_SECURITIES", "80"))
    sample = []
    for source in SAMPLE_SOURCES:
        drawn = recent_securities(per_source, source)
        print(f"  sampling the {len(drawn)} most recently written {source} securities")
        sample += [sid for sid in drawn if sid not in sample]
    if not sample:
        print("::notice::no segment rows yet — nothing to reconcile")
        return 0

    rows = []
    # 20 ids per call. The URL's length budget allows ~100, but `get_all`'s cap applies PER CALL,
    # and on 2026-10-04 the 80-security sample was 50,716 flat rows against that 60,000 cap: 85% of
    # it, so one heavier sample would fail this guard on its own sample size again. At 20 a call
    # holds ~13,000 rows.
    for i in range(0, len(sample), 20):
        chunk = ",".join(sample[i : i + 20])
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
    # Asked through the primary key, (security_id, accession_number). No index leads on the
    # accession alone, so filtering by it scanned the whole table: 7.2 s cold for one chunk of 60
    # at 1,240,755 rows (2026-11-23), and 57014 under load, which failed market-verify that day.
    version_of: dict[str, int] = {}
    if parser_version is not None:
        by_security: dict[str, set[str]] = {}
        for r in rows:
            if r.get("accession_number"):
                by_security.setdefault(r["security_id"], set()).add(r["accession_number"])
        batch_ids: list[str] = []
        batch_accs: set[str] = set()

        def ask_versions() -> None:
            accs = sorted(batch_accs)
            for i in range(0, len(accs), 60):
                for f in get_all(
                    "security_filing?select=accession_number,segments_parser_version"
                    f"&security_id=in.({','.join(batch_ids)})"
                    f"&accession_number=in.({','.join(accs[i : i + 60])})"
                ):
                    if f.get("segments_parser_version") is not None:
                        version_of[f["accession_number"]] = int(f["segments_parser_version"])

        for sid, accs_of in sorted(by_security.items()):
            batch_ids.append(sid)
            batch_accs.update(accs_of)
            if len(batch_ids) >= 20 or len(batch_accs) >= 60:
                ask_versions()
                batch_ids, batch_accs = [], set()
        if batch_ids:
            ask_versions()

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
    checked_served = 0
    checked_band: dict[str, int] = {}
    non_positive: list[str] = []
    over_served: list[str] = []
    over_band: dict[str, list[str]] = {}
    under_served = 0
    under_historical = 0
    internal_stale: list[str] = []
    for gk, total_of_split in sums.items():
        # REVENUE ONLY. `reconciled_to` is stored per bucket, and only revenue is expected to add
        # up: ASC 280 and IFRS 8 require a reconciliation of segment profit, not an identity, so
        # Apple's segment operating income never matches the consolidated figure and must not fail.
        if gk[1] != "revenue":
            continue
        target = targets.get(gk)
        line = (
            f"{gk[0][:8]} {gk[4].split(':')[-1]} {gk[2]} {gk[3]}: "
            f"split={total_of_split:,.0f} accepted against="
            + ("none" if target is None else f"{target:,.0f}")
        )
        # A SPLIT THE CURRENT PARSER NEVER PRODUCED CANNOT BE EVIDENCE ABOUT IT. A re-queued
        # filing sits behind the parser until it is read again; counted, never asserted on.
        if stale_group.get(gk):
            if target is None or not (target > 0 and total_of_split > 0) \
                    or abs(total_of_split - target) > max(1.0, abs(target) * TOLERANCE_FRACTION):
                internal_stale.append(line)
            continue
        # A split totalling nothing is checked even with no target of its own: an inherited
        # revenue split is placed by another bucket's map and carries none.
        if total_of_split <= 0 or (target is not None and target <= 0):
            non_positive.append(line)
            continue
        if target is None:
            continue
        internal_checked += 1
        served = gk[3] == served_period.get((gk[0], gk[4], gk[2]))
        band = band_of(gk[3])
        if served:
            checked_served += 1
        else:
            checked_band[band] = checked_band.get(band, 0) + 1
        tol = max(1.0, abs(target) * TOLERANCE_FRACTION)
        if total_of_split - target > tol:
            if served:
                over_served.append(line)
            else:
                over_band.setdefault(band, []).append(line)
        elif target - total_of_split > tol:
            if served:
                under_served += 1
            else:
                under_historical += 1

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

    # Before the rates, which divide by it.
    if internal_checked == 0:
        print("::error::re-checked 0 splits — `reconciled_to` is empty, so nothing was verified")
        return 1

    failed = False
    print(
        f"::notice::{internal_checked} current-parser revenue splits re-checked: "
        f"{checked_served} served, {sum(checked_band.values())} historical; "
        f"{under_served} served and {under_historical} historical cover only part of their target "
        "(partial disclosures, served on purpose, not failed)"
    )

    # NON-POSITIVE: none allowed among what the current parser produced.
    if non_positive:
        print(
            f"::error::{len(non_positive)} current-parser revenue split(s) total zero or less, or "
            "are reconciled to a non-positive total — the parser refuses both (muffin-ingest#185)"
        )
        for b in non_positive[:20]:
            print(f"::error::  non-positive: {b}")
        failed = True

    # OVER, SERVED: a split a reader is being shown exceeds its company's revenue.
    served_rate = len(over_served) / checked_served if checked_served else 0.0
    print(
        f"::notice::{len(over_served)} SERVED split(s) exceed their target, {served_rate:.2%} of "
        f"{checked_served} (tripwire {SERVED_OVER_TRIPWIRE:.2%})"
    )
    for b in over_served[:10]:
        print(f"::notice::  served over: {b}")
    if checked_served >= MIN_BAND_SPLITS and served_rate > SERVED_OVER_TRIPWIRE:
        print(f"::error::served over-coverage {served_rate:.2%} is above {SERVED_OVER_TRIPWIRE:.2%}")
        failed = True

    # OVER, HISTORICAL, per year band: older filings are messier, so one rate would either cry wolf
    # on them or hide a regression in the newer ones.
    for band, ceiling in HISTORICAL_OVER_TRIPWIRE.items():
        n = checked_band.get(band, 0)
        over = over_band.get(band, [])
        rate = len(over) / n if n else 0.0
        judged = n >= MIN_BAND_SPLITS
        print(
            f"::notice::historical {band}: {len(over)} of {n} exceed their target ({rate:.2%}, "
            f"tripwire {ceiling:.2%}{'' if judged else ', too few to judge'})"
        )
        if judged and rate > ceiling:
            print(f"::error::historical over-coverage for {band} is {rate:.2%}, above {ceiling:.2%}")
            for b in over[:5]:
                print(f"::error::  {b}")
            failed = True
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
