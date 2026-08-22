"""The app's own reads must answer inside the anon statement timeout.

WHY THIS EXISTS. `anon` has a 3-second statement timeout and `service_role` has none, so a slow
view fails for the APP while every service-role probe reports it healthy. That has now happened
three times:

  * `fund_sector_weight` answered service_role in 7.2s and gave anon `57014`; the Markets donut had
    been failing in the deployed app while every probe said fine.
  * `security_facets` was fine filtered by country, by sector, or by tier — and timed out for tier
    AND sector together, because two filters collapse the row estimate and flip the plan.
  * `price_series` answered `symbol=eq.AAPL` in 696 ms and TIMED OUT for
    `symbol=eq.AAPL & grain=eq.daily` — broken by the filter it had just been given, one deploy
    after the column was added.

Every one was invisible to a functional check: the data was correct, the grants were right, and
the only symptom was a screen that did not load.

So this times the CONJUNCTIONS the app actually sends, as ANON, against the real ceiling. It is a
latency check on purpose — a correctness check cannot see any of the three.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ["BASE"].rstrip("/")
ANON = os.environ["ANON"]
UA = "muffin-market-verify/1.0"

# The anon ceiling is 3s. Failing at 2.5s leaves no room to report a REGRESSION before it becomes
# an outage — a query that has crept to 2.9s is already broken for a user on a slow connection.
BUDGET_MS = 2000

# Each entry is a query some screen makes, with the filters it really applies. A single-filter
# probe would have passed every one of the three incidents above.
QUERIES = [
    ("stock chart, daily", "price_series?select=date,close&symbol=eq.AAPL&grain=eq.daily&order=date"),
    ("stock chart, weekly", "price_series?select=date,close&symbol=eq.AAPL&grain=eq.weekly&order=date"),
    ("stock chart, local listing", "price_series?select=date,close&symbol=eq.SAP.DE&grain=eq.daily&order=date"),
    ("stock statements", "security_statement_current?select=period_ending,reporting_currency,data&symbol=eq.AAPL&statement=eq.income&order=period_ending.desc&limit=4"),
    ("markets donut", "fund_sector_weight?select=sector_id,weight&limit=100"),
    ("screener, two filters", "security_facets?select=security_id&msci_tier=eq.developed&sector_id=eq.information-technology&limit=50"),
    ("country macro panel", "macro_current?select=code,name,value,as_of&country_iso2=eq.US"),
    # The ratio series range-joins 3.4M price bars to 2.1M metric rows, so it is the biggest join
    # the app sends and it carries the same two-filter shape that broke `price_series` — symbol
    # AND grain. Both grains are timed: weekly reaches back to 2006 and returns the most rows.
    ("stock P/E chart, daily", "security_ratio_series?select=date,close,pe_ratio&symbol=eq.AAPL&grain=eq.daily&order=date"),
    ("stock P/E chart, weekly", "security_ratio_series?select=date,close,pe_ratio&symbol=eq.AAPL&grain=eq.weekly&order=date"),
    # A non-USD filer, where the currency gate does the withholding — the branch a US-only probe
    # never reaches.
    ("stock P/E chart, local listing", "security_ratio_series?select=date,pe_ratio,currency_comparable&symbol=eq.SAP.DE&grain=eq.daily&order=date"),
    # A self-join over the sector's members. It was 0.89s built on `security_current` (whose sector
    # comes from a lateral, so the cost was paid per sector member) and moved to the materialised
    # spine for that reason — a sector grows with every promoted listing, and this is the fourth
    # view in this schema to be one filter away from the anon timeout.
    ("stock peers", "security_peers?select=peer_symbol,peer_market_cap_usd,size_distance&security_id=eq.1b68c902-a3dc-4cc9-8574-f431dacfd834&order=size_distance&limit=8"),
    # Leadership joins `security_officer` to `security` for the pay currency, and the app sends it
    # with a security filter AND two orderings — the shape that has broken four views here. SK hynix
    # deliberately: it is the non-USD case the currency expression exists for, so a probe against a
    # US company would never evaluate the branch that does the work.
    ("stock leadership", "security_leadership?select=name,title,pay,pay_currency,is_ceo&security_id=eq.09a147af-5ec6-45f3-8db7-fe0f2403e6ed&order=is_ceo.desc&order=pay.desc.nullslast&limit=12"),
]


def timed(path: str):
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={"apikey": ANON, "Authorization": f"Bearer {ANON}",
                 "Accept-Profile": "market", "User-Agent": UA},
    )
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read()
        ms = int((time.monotonic() - t0) * 1000)
        return ms, len(json.loads(body or b"[]")), None
    except urllib.error.HTTPError as e:
        ms = int((time.monotonic() - t0) * 1000)
        detail = e.read()[:200].decode("utf-8", "replace")
        return ms, 0, f"HTTP {e.code}: {detail}"
    except Exception as e:  # noqa: BLE001 — a timeout here is the finding, not an accident
        return int((time.monotonic() - t0) * 1000), 0, f"{type(e).__name__}: {e}"


def main() -> int:
    bad = 0
    for label, path in QUERIES:
        ms, n, err = timed(path)
        if err:
            # A statement timeout is the headline case and says so explicitly, because "HTTP 500"
            # reads as a server fault rather than as a query that is too slow for this role.
            hint = " — anon statement timeout" if "57014" in err else ""
            print(f"::error::{label}: {err[:160]}{hint}")
            bad = 1
        elif ms > BUDGET_MS:
            print(f"::error::{label} took {ms}ms against a {BUDGET_MS}ms budget "
                  f"(anon's hard ceiling is 3000ms) — {n} rows")
            bad = 1
        else:
            print(f"  ok   {label}: {ms}ms, {n} rows")
    return bad


if __name__ == "__main__":
    sys.exit(main())
