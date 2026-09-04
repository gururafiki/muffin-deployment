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
    #
    # ONE COMMA-JOINED `order`, NOT TWO PARAMETERS. Written as `&order=a&order=b` first, which is
    # what chaining two `.order()` calls LOOKS like it produces; PostgREST silently honours only one
    # of them. Measured — the two forms return different rows — so that probe was timing a query the
    # app never sends, which is precisely what this guard exists to prevent.
    ("stock leadership", "security_leadership?select=name,title,pay,pay_currency,is_ceo&security_id=eq.09a147af-5ec6-45f3-8db7-fe0f2403e6ed&order=is_ceo.desc,pay.desc.nullslast&limit=12"),
    # ── The business-lines section (Sankey + donuts), added when the stock page first read the
    # segment views. Apple, because it is the deepest filer here: three axes, a nested split, and
    # eighteen years of filings behind the one period the view must choose.
    #
    # `security_segment_current` is `security_segment_latest` twice over (a dense_rank across
    # filings, then a period choice across years), and BOTH views sit above a table that grows with
    # every filing parsed — 245,000 of them queued. It is exactly the shape that timed out for anon
    # while answering service_role fine in `fund_sector_weight`, `security_facets` and
    # `price_series`, so it is timed here before it can do it a fourth time.
    ("stock business lines", "security_segment_current?select=axis,kind,member_code,member_label,concept_name,revenue,operating_income,operating_margin_pct,revenue_share_pct,currency_code,period_ending&security_id=eq.1b68c902-a3dc-4cc9-8574-f431dacfd834&order=revenue.desc.nullslast"),
    ("stock business lines, nested", "security_segment_detail?select=parent_axis,parent_member,member_code,concept_name,revenue,operating_income,share_of_parent_pct,currency_code&security_id=eq.1b68c902-a3dc-4cc9-8574-f431dacfd834&order=revenue.desc.nullslast"),
    # The Sankey's right half. Six metric codes for one security across every annual period it has —
    # an `in.()` over a table of 3.29M rows, which is a different plan from the single-metric reads
    # already timed above.
    ("stock income flow", "security_metric?select=metric_code,value,as_of,currency_code&security_id=eq.1b68c902-a3dc-4cc9-8574-f431dacfd834&period_type=eq.annual&metric_code=in.(revenue,gross_profit,operating_income,pretax_income,income_tax,net_income)&order=as_of.desc&limit=18"),
]


def timed(path: str, attempts: int = 3):
    """Time a read, BEST OF `attempts`.

    A SINGLE READING IS A MEASUREMENT OF A MOMENT, NOT OF THE QUERY, and this check cried wolf twice
    in one day on the same one. `stock statements` reported 2,166 ms against a 2,000 ms budget on
    2026-09-02 and a hard `57014` statement timeout on 2026-09-04, both immediately after a deploy —
    and re-measured 0.34-0.65 s across five runs and three symbols each time. The node runs matview
    refreshes, a PostgREST reload and eight ingestion resources; contention is normal and is not
    what this guard is for.
    
    Best-of-three, because the failure this exists to catch is a query that is SLOW BY
    CONSTRUCTION — a plan flip, a lost index, a view that grew a lateral. That is slow every time,
    so the best of three is still over budget. A guard that fires on contention is one that gets
    ignored, and then the plan flip it exists for goes unnoticed.
    """
    best = None
    for attempt in range(attempts):
        ms, rows, err = _timed_once(path)
        if err is None and (best is None or ms < best[0]):
            best = (ms, rows, None)
        elif err is not None and best is None:
            best = (ms, rows, err)
        # A clean read under budget is the answer; no point paying for more.
        if err is None and ms <= BUDGET_MS:
            return ms, rows, None
        if attempt < attempts - 1:
            time.sleep(1.5)
    return best


def _timed_once(path: str):
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
