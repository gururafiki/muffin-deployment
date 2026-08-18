#!/usr/bin/env python3
"""
A UNIT FLIP IS INVISIBLE PER ROW AND OBVIOUS IN THE MEDIAN.

`equity/fundamental/metrics` mixes conventions WITHIN ONE RESPONSE — `profit_margin` and
`return_on_equity` are FRACTIONS while `dividend_yield` is already a PERCENT, and
`dividend_yield_5y_avg` is a fraction again. One shared `pct()` once rendered NVIDIA at a 46%
dividend yield: wrong by two orders of magnitude and entirely plausible-looking.

WHY THE MEDIAN AND NOT A PER-ROW RANGE. Measured 2026-08-18 over 1,000 securities, a per-row band
flags real companies:

    profit_margin  > 5   ->  11 securities, and they are INVESTMENT HOLDING COMPANIES
                             (Tamburi, Priortech) where net income over tiny revenue genuinely
                             exceeds 100%. Arithmetically real, not a defect.
    dividend_yield > 30  ->   9 securities, special dividends and post-collapse trailing yields.

So a per-row guard cries wolf on correct data, and a guard that cries wolf gets deleted. The MEDIAN
cannot: if openbb or yfinance ever flips a convention, every row moves together and the median jumps
by ~100x. That is the failure this exists to catch, and it is the only one it claims to catch.

Bands are set around the measured medians with an order of magnitude of headroom either side —
wide enough that a market-wide shift in real margins never trips it, narrow enough that a
fraction/percent flip always does.
"""
import json
import os
import sys
import urllib.request

BASE = os.environ["BASE"]
ANON = os.environ["ANON"]

# field -> (convention, low, high) for the MEDIAN. Measured 2026-08-18:
#   profit_margin 0.1275 · dividend_yield 2.74 · return_on_equity 0.1435
BANDS = {
    "profit_margin":    ("fraction", 0.01, 1.0),
    "return_on_equity": ("fraction", 0.01, 1.0),
    "dividend_yield":   ("percent",  0.30, 30.0),
}


def fetch(path: str):
    req = urllib.request.Request(
        f"{BASE}/rest/v1/{path}",
        headers={
            "apikey": ANON,
            "Authorization": f"Bearer {ANON}",
            "Accept-Profile": "market",
            # urllib's default User-Agent gets a 403 from Cloudflare on this host, which reads
            # exactly like an auth failure and is not.
            "User-Agent": "muffin-market-verify",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def median(values):
    s = sorted(values)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def main() -> int:
    cols = ",".join(BANDS)
    rows = fetch(f"security_fundamentals?select={cols}&limit=1000")
    if len(rows) < 100:
        print(f"::error::only {len(rows)} fundamentals rows — too few to judge a distribution")
        return 1

    failed = False
    for field, (convention, low, high) in BANDS.items():
        vals = [r[field] for r in rows if isinstance(r.get(field), (int, float))]
        if len(vals) < 100:
            print(f"::error::{field}: only {len(vals)} numeric values — cannot judge the unit")
            failed = True
            continue
        m = median(vals)
        if not (low <= m <= high):
            # Name the LIKELY DIRECTION, because "out of band" alone sends the next person to the
            # wrong place. A ~100x jump is a fraction being served as a percent, or the reverse.
            hint = "looks like a FRACTION served as a PERCENT" if m > high else "looks like a PERCENT served as a FRACTION"
            print(
                f"::error::{field} median is {m:.4f}, expected a {convention} in [{low}, {high}] — {hint}"
            )
            failed = True
        else:
            print(f"  ok   {field} median = {m:.4f} ({convention}, band {low}-{high}, n={len(vals)})")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
