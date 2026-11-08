"""A derived metric must equal the number in the filing it came from.

`security-metrics` reports a `written` count. That count is satisfied by writing the WRONG number
just as well as the right one — it says a row was produced, not that the row is true. The only
check that can tell them apart compares the served value against the raw provider jsonb it was
derived from, which this pipeline already stores beside it.

Three ways this goes wrong, all silent:

  * THE FIELD MAPPING DRIFTS. `sec` and `yfinance` share 4 of 40 income-statement field names, so
    every metric's provider spelling is a row in `metric_source_field`. A provider renaming a field
    produces no error — the metric simply stops appearing, and the chart is merely shorter.
  * A METRIC READS THE WRONG PROVIDER'S FIELD. Pre-tax income is `total_pretax_income` on one and
    `total_pre_tax_income` on the other. Reading the wrong one yields null, not a mistake.
  * THE VALUE IS TRANSFORMED WHEN IT SHOULD NOT BE, OR NOT WHEN IT SHOULD. An outflow is stored
    negative (migration 20261108235000): SEC company facts state capex, buybacks and dividends paid
    as positive payments and carry `sign = -1`, while Yahoo states them negative and carries 1. A
    reported metric is the provider's number times that sign, and nothing else.

So: sample real securities, and for each reported (non-derived) metric assert the served value is
exactly the number in `security_statement.data` under that provider's own field name, times the
provider's `sign`.
"""
import datetime
import json
import os
import sys
import urllib.parse
import urllib.request

BASE = os.environ["BASE"].rstrip("/")
KEY = os.environ["SRV"]
# urllib's default User-Agent gets a 403 from Cloudflare on supabase.<domain>, which reads exactly
# like an auth failure and is not.
UA = "muffin-market-verify/1.0"
#: How many securities of each source are compared: 14 a source keeps the 40 statement requests
#: the single sample made.
SECURITIES_PER_SOURCE = 14
#: Metric rows read for each sampled security, the first in key order. Enough to span the three
#: statements of a few periods; the statement fetch takes their periods in one `in.()`.
ROWS_PER_SECURITY = 40


def key_starts(n: int) -> list[str]:
    """`n` lower bounds for `security_id`, spread evenly over the uuid space and shifted by the day.

    Each bound reads the first security at or after it through the primary key, so a sample costs
    `n` index probes whatever the table's size, and the day moves which securities are read.
    """
    phase = (datetime.date.today().toordinal() % 97) / 97
    return [
        f"{int((i + phase) / n * 0xFFFFFFFF):08x}-0000-0000-0000-000000000000" for i in range(n)
    ]


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
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b"[]")


def main() -> int:
    fields = get("metric_source_field?select=metric_code,source_code,statement,field,sign")
    mapping = {(m["metric_code"], m["source_code"], m["statement"]): m["field"] for m in fields}
    signs = {(m["metric_code"], m["source_code"]): int(m["sign"]) for m in fields}
    if not mapping:
        print("::error::metric_source_field is EMPTY — every metric would silently produce nothing")
        return 1

    # STATEMENT-DERIVED ROWS ONLY: the sources `metric_source_field` names, because those are the
    # rows derived FROM A STATEMENT DOCUMENT. Sampling every source by recency once made this check
    # report "compared 0 values" the day `security-xbrl` started: the newest 300 rows were all
    # written straight from company facts, none had a statement to compare with, and the guard
    # fired on its own blind spot rather than on drift. Failing loudly there was correct; a check
    # that verified nothing must never read as one that passed.
    #
    # SAMPLED PER SOURCE, BY KEY. One sample across every source is filled by whichever source
    # wrote last (measured 2026-10-28: the newest 300 were all yfinance), so each source gets its
    # own securities and its own count.
    #
    # NOT BY RECENCY ANY MORE. `order=fetched_at.desc` has no index, so each read was a parallel
    # sequential scan of the whole table, and Phase 5's CIK grid took it to 6.8 M rows: 0.77 s warm
    # on 2026-11-04, and past the 8-second ceiling of `service_role` while the SEC lanes write. This
    # check answered HTTP 500 on 11-02, 11-03 and 11-04, each run inside the filer sensor's weekday
    # tick. A lower bound on `security_id` reads through the primary key instead: 3-52 ms a probe,
    # measured as `service_role` the same evening, and the day still rotates the sample.
    by_sec: dict[str, list[dict]] = {}
    sources = sorted({s for _, s, _ in mapping})
    for source in sources:
        taken: set[str] = set()
        for start in key_starts(SECURITIES_PER_SOURCE):
            rows = get(
                "security_metric?select=security_id,metric_code,period_type,as_of,value,source_code"
                f"&source_code=eq.{urllib.parse.quote(source)}&security_id=gte.{start}"
                f"&order=security_id,metric_code,period_type,as_of&limit={ROWS_PER_SECURITY}"
            )
            if not rows:
                continue
            # The first security at or after the bound; two bounds can reach the same one where a
            # source is sparse, and it is compared once.
            sec_id = rows[0]["security_id"]
            if sec_id in taken:
                continue
            taken.add(sec_id)
            by_sec.setdefault(sec_id, []).extend(r for r in rows if r["security_id"] == sec_id)
    if not by_sec:
        print(
            "::error::security_metric holds no rows derived from a statement document "
            f"(sources: {', '.join(sources)}) — the derivation has produced nothing"
        )
        return 1

    checked = 0
    per_source: dict[str, int] = {s: 0 for s in sources}
    bad: list[str] = []
    for sec_id, metrics in by_sec.items():
        periods = {m["as_of"] for m in metrics}
        # `in.()` is a URL, so its chunk size is a LENGTH budget — these are tiny, but keep the
        # habit: a 500-value `in.()` is a ~6.5 KB URL and the proxy answers a bare 502.
        plist = ",".join(sorted(periods))
        stmts = get(
            "security_statement?select=statement,period_ending,period_type,data,source_code"
            f"&security_id=eq.{sec_id}&period_ending=in.({urllib.parse.quote(plist)})"
        )
        # PERIOD TYPE IS PART OF THE KEY, BECAUSE A FISCAL-YEAR END IS BOTH AN ANNUAL PERIOD AND A
        # FOURTH-QUARTER ONE.
        #
        # Indexed on (statement, period_ending) alone, a security holding both an annual and a
        # quarterly filing for 2025-12-31 keeps whichever row this dict happened to see LAST, and
        # the annual metric is then compared against three months of revenue. Measured 2026-08-22:
        # 27 "disagreements", every one a served annual figure against a quarterly filing, ratios of
        # 2.9-4.8 — the arithmetic signature of a year over a quarter, not of drift. The data was
        # right throughout; this check predates migration 106, which added quarterly statements and
        # put `period_type` into the primary key and into both writers' conflict and dedupe keys.
        # It was the one place the column never reached.
        #
        # AND THE PROVIDER IS PART OF IT SINCE THE STATEMENT KEY CARRIES IT (migration
        # 20261025140000): `sec` and yfinance can each hold a row for one period, in their own
        # vocabularies, and a metric must be compared with the statement of its own source.
        index = {
            (s["statement"], s["period_ending"], s["period_type"], s["source_code"]): s
            for s in stmts
        }

        for m in metrics:
            for stmt_kind in ("income", "balance", "cash"):
                field = mapping.get((m["metric_code"], m["source_code"], stmt_kind))
                if field is None:
                    continue
                src = index.get((stmt_kind, m["as_of"], m["period_type"], m["source_code"]))
                if src is None:
                    continue
                raw = (src.get("data") or {}).get(field)
                if not isinstance(raw, (int, float)):
                    continue
                checked += 1
                per_source[m["source_code"]] += 1
                # Exact, not approximate. The derivation copies the number in the metric's own sign;
                # it does not compute it.
                sign = signs[(m["metric_code"], m["source_code"])]
                if sign * float(raw) != float(m["value"]):
                    bad.append(
                        f"{m['metric_code']} for {sec_id[:8]} {m['as_of']} "
                        f"({m['source_code']}.{field}, sign {sign}): served {m['value']}, "
                        f"filing says {raw}"
                    )
                break

    if checked == 0:
        # A CHECK THAT VERIFIED NOTHING MUST NOT REPORT SUCCESS. Every row failing to match a
        # mapping is itself the drift this exists to catch.
        print(
            "::error::derived-metric check compared 0 values — every sampled metric failed to "
            "resolve a provider field, which is exactly what a mapping drift looks like"
        )
        return 1

    if bad:
        print(f"::error::{len(bad)} derived metrics disagree with the filing they came from")
        for b in bad[:10]:
            print(f"::error::  {b}")
        return 1

    print(f"  ok   derived metrics match their filing = {checked} values compared")
    for source, n in per_source.items():
        print(f"  ok   derived metrics compared, {source} = {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
