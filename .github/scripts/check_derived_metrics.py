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
  * THE VALUE IS TRANSFORMED WHEN IT SHOULD NOT BE. Capex is negative on one provider and positive
    on the other; free cash flow normalises the sign deliberately, and a REPORTED metric must not.

So: sample real securities, and for each reported (non-derived) metric assert the served value is
exactly the number in `security_statement.data` under that provider's own field name.
"""
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
    mapping = {
        (m["metric_code"], m["source_code"], m["statement"]): m["field"]
        for m in get("metric_source_field?select=metric_code,source_code,statement,field")
    }
    if not mapping:
        print("::error::metric_source_field is EMPTY — every metric would silently produce nothing")
        return 1

    # Sample the most recently derived rows: they are the ones a mapping change would break first,
    # and a stale sample would keep passing long after a rename.
    rows = get(
        "security_metric?select=security_id,metric_code,period_type,as_of,value,source_code"
        "&source_code=neq.derived&order=fetched_at.desc&limit=300"
    )
    if not rows:
        print("::error::security_metric holds no reported rows — the derivation has produced nothing")
        return 1

    checked = 0
    bad: list[str] = []
    # Group by security so the statement fetch is one request per security, not per metric.
    by_sec: dict[str, list[dict]] = {}
    for r in rows:
        by_sec.setdefault(r["security_id"], []).append(r)

    for sec_id, metrics in list(by_sec.items())[:40]:
        periods = {m["as_of"] for m in metrics}
        # `in.()` is a URL, so its chunk size is a LENGTH budget — these are tiny, but keep the
        # habit: a 500-value `in.()` is a ~6.5 KB URL and the proxy answers a bare 502.
        plist = ",".join(sorted(periods))
        stmts = get(
            "security_statement?select=statement,period_ending,data,source_code"
            f"&security_id=eq.{sec_id}&period_ending=in.({urllib.parse.quote(plist)})"
        )
        index = {(s["statement"], s["period_ending"]): s for s in stmts}

        for m in metrics:
            for stmt_kind in ("income", "balance", "cash"):
                field = mapping.get((m["metric_code"], m["source_code"], stmt_kind))
                if field is None:
                    continue
                src = index.get((stmt_kind, m["as_of"]))
                if src is None:
                    continue
                raw = (src.get("data") or {}).get(field)
                if not isinstance(raw, (int, float)):
                    continue
                checked += 1
                # Exact, not approximate. The derivation copies the number; it does not compute it.
                if float(raw) != float(m["value"]):
                    bad.append(
                        f"{m['metric_code']} for {sec_id[:8]} {m['as_of']} "
                        f"({m['source_code']}.{field}): served {m['value']}, filing says {raw}"
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
