---
name: market-health
description:
  Check whether the market data is actually healthy — coverage, backlog depth, and
  the shape assertions. Use when someone asks "how complete is the data", "is the
  ingestion working", before or after a big change, or to answer what is left.
  Reports what is real rather than what looks plausible.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Is the market data healthy?

## The quick answer: run the real verifier

```bash
gh workflow run market-verify.yml --ref main
```

39 assertions as `anon` — floors on the universe, zero-CUSIP and zero-ISIN checks, duplicate
detection, backlog satisfiability, fabricated-return tripwires, the mega-cap canary, per-country
symbol coverage, and resource health. It runs daily at 03:00 UTC anyway.

**It asserts SHAPE, not exceptions**, because every defect it was written for returned HTTP 200.

## Coverage, measured

```bash
BASE=https://supabase.rafiki.guru
ANON=<SUPABASE_ANON_KEY>
cnt() { curl -sS -o /dev/null -D - "$BASE/rest/v1/$1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H 'Accept-Profile: market' -H 'Prefer: count=exact' \
  | sed -n 's/.*content-range: [0-9*-]*\///Ip' | tr -d '\r'; }

E='security?security_type_code=eq.equity'
echo "equities:        $(cnt "$E&select=security_id")"
echo "  with a sector: $(cnt 'security_current?security_type_code=eq.equity&sector_id=not.is.null&select=security_id')"
echo "  with industry: $(cnt 'security_current?security_type_code=eq.equity&industry=not.is.null&select=security_id')"
echo "  with mkt cap:  $(cnt "$E&market_cap=not.is.null&select=security_id")"
echo "  fundamentals:  $(cnt 'security_fundamentals_current?select=security_id')"
```

Reference figures, 2026-08-13: 12,348 equities — fundamentals 92%, sector 89%, market cap 66%,
industry 61%, statements ~12.5%.

## Two traps when reading coverage

**1. `security_statement_current` returns ROWS, not securities** — about twelve per security
(3 statements x 4 periods). A row count reads as ~12x the real coverage; it once produced a "104%
coverage" figure, which is the kind of impossible number that means the metric is wrong rather than
the data. Get the honest number from backlog arithmetic instead:

```
equities − pending_statements − statements_missing_at = securities that actually have statements
```

**2. The TOTAL security count is not the equity universe.** Bonds outnumber equities (15,159 vs
12,348) since the fixed-income funds were added. Every serving view and backlog filters
`security_type_code = 'equity'`, so a bug that retyped equities would empty the app while leaving
the total untouched. `market-verify` has a separate equity floor for exactly this.

## Backlog depth

```bash
for v in pending_yahoo_symbol pending_local_symbol pending_profile pending_industry \
         pending_prices pending_performance pending_fundamentals pending_statements; do
  printf '%-24s %s\n' "$v" "$(cnt "$v?select=security_id&limit=1")"   # needs SERVICE_ROLE, not anon
done
```

**Zero is only good news if it got there by working.** A backlog empties either by fetching the data
or by marking securities unanswerable, and the counts look identical. Cross-check:

```bash
# should be ~0 of ~213 — it read 109 during the 2026-08-13 incident
cnt 'security?select=security_id&country_iso2=eq.US&market_cap=gt.50000000000&industry_missing_at=not.is.null'
```

## Is every resource still running?

```bash
curl -sS "$BASE/rest/v1/refresh_log?select=resource,finished_at,ok,error&order=resource" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Accept-Profile: market'
```

One row per resource, holding its LAST run. `ok: false` with an `error` is a resource telling you
what went wrong. A row with `finished_at: null` older than an hour is a worker that died mid-run —
the in-flight TTL is 2 minutes, so it is not blocking anything; it clears on the next successful run.

## What "healthy but incomplete" looks like right now

Genuinely blocked, and not by engineering:

- **GICS proper** — needs a licence. yfinance/finviz taxonomies are the proxy.
- **Total return / dividends** — everything is a *price* return, which understates high-yield markets.
- **Index membership** — FMP premium, partially substitutable by fund holdings.
- **FMP entirely** — openbb calls its v3 API, which now 403s for anyone without a pre-August-2025
  subscription. No key fixes this.

Structurally impossible: non-US UCITS funds, commodity trusts and pools (SLV, USO, DBC), unit
investment trusts (MDY) — none files N-PORT.
