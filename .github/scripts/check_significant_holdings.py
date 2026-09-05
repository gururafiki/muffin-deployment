#!/usr/bin/env python3
"""A security that is a top holding of a sector fund is never "unanswerable".

WHY THIS EXISTS BESIDE THE MEGA-CAP CHECK. `market-verify` already asserts that few US mega-caps
carry a `*_missing_at` mark, and on 2026-08-14 it reported `statements_missing_at = 0 of 213` on a
morning when 85 of the 221 securities that are a >=1.5% holding of a sector fund were marked —
Exelon, Intuitive Surgical, Martin Marietta, Essex Property Trust, IFF. Driving `security-refresh`
at ISRG, EXC and MLM returned 12 rows of statements each, so the marks were false.

The mega-cap check has three blind spots and that incident walked through all of them:

  * securities with NO market cap at all   ISRG had none, and 34% of the universe still does not
  * securities below $50bn                 EXC $46bn, MLM $33bn, ESS $19bn
  * every non-US security                  Chubb is Swiss

Market cap cannot be the only lens on a universe that is two-thirds uncapped and mostly not
American — and it is stored in each security's own currency, which is why that check is US-only and
has to stay that way. WEIGHT has neither problem: it is a percentage of a fund, so it is free of
currency, market cap and country, and "a top-ten holding of a sector ETF" is an unambiguous
statement that a security matters.

WHY A SCRIPT rather than inline curl. The obvious PostgREST spelling does not work: embedding
`security` with `sector_constituents` is ambiguous (PGRST201) because both are reachable through
`fund_holding` as a many-to-many, and every disambiguation it suggests is that fund join rather
than the direct match on `security_id` this needs. So the two sets are fetched and intersected
here — which is also somewhere the paging can be got right, since a `.limit()` above
`PGRST_DB_MAX_ROWS` (1000) is not an error, just a shorter answer.

Reads BASE and ANON from the environment. Prints one line per column; exits 1 if any trips.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

# A handful of these can legitimately be unanswerable — a newly listed line, a security the
# provider genuinely has no statements for. Dozens cannot.
TRIPWIRE = 15
# Below this the WEIGHTS have stopped loading, and an empty comparison set would make every
# column read as healthy. A guard that passes because it measured nothing is not a guard.
MIN_POPULATION = 50
MIN_WEIGHT = 1.5
COLUMNS = ("industry_missing_at", "statements_missing_at", "performance_missing_at")
PAGE = 1000


def fetch_ids(base: str, anon: str, path: str) -> set[str]:
    """Every `security_id` matching `path`, paged — the row cap is silent, not an error."""
    out: set[str] = set()
    offset = 0
    while True:
        url = f"{base}/rest/v1/{path}&limit={PAGE}&offset={offset}"
        req = urllib.request.Request(
            url,
            headers={
                "apikey": anon,
                "Authorization": f"Bearer {anon}",
                "Accept-Profile": "market",
                # Cloudflare rejects urllib's default agent with a 403 that reads like an auth
                # failure and is not one.
                "User-Agent": "muffin-market-verify/1.0",
            },
        )
        with urllib.request.urlopen(req, timeout=60) as res:
            rows = json.load(res)
        if not rows:
            return out
        out.update(r["security_id"] for r in rows)
        offset += PAGE
        # The universe is ~27k securities; anything past this is a paging bug, not a big table.
        if offset > 60_000:
            raise RuntimeError(f"refusing to page past {offset} rows for {path}")


def main() -> int:
    base = os.environ.get("BASE", "").rstrip("/")
    anon = os.environ.get("ANON", "")
    if not base or not anon:
        print("::error::check_significant_holdings needs BASE and ANON")
        return 1

    try:
        # ORDERED, because `fetch_ids` pages by offset and an unordered paged read can SKIP rows
        # entirely — silently shrinking the population this check is asserting over. Duplicates are
        # harmless here (the ids become a set); the skips are not, and they are invisible.
        heavy = fetch_ids(base, anon, f"sector_constituents?select=security_id&weight=gte.{MIN_WEIGHT}&order=security_id")
    except (urllib.error.URLError, RuntimeError, ValueError) as exc:
        print(f"::error::significant-holding check — could not read the weighted set: {exc}")
        return 1

    if len(heavy) < MIN_POPULATION:
        print(
            f"::error::only {len(heavy)} securities are a >={MIN_WEIGHT}% holding — fund weights "
            "have stopped loading, so this check would pass by measuring nothing"
        )
        return 1

    failed = False
    for col in COLUMNS:
        try:
            marked = fetch_ids(base, anon, f"security?select=security_id&{col}=not.is.null&order=security_id")
        except (urllib.error.URLError, RuntimeError, ValueError) as exc:
            print(f"::error::significant-holding check ({col}) — could not read a count: {exc}")
            failed = True
            continue
        hits = len(marked & heavy)
        if hits > TRIPWIRE:
            print(
                f"::error::{hits} of {len(heavy)} significant fund holdings carry {col} — a "
                "provider refusal is being recorded as dead securities, and market cap cannot see it"
            )
            failed = True
        else:
            print(f"  ok   significant holdings carrying {col} = {hits} of {len(heavy)} (tripwire at {TRIPWIRE})")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
