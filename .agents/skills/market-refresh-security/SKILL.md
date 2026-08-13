---
name: market-refresh-security
description:
  Refresh ONE security immediately — returns, market cap, fundamentals and
  statements. Use when someone says a specific stock page looks stale, empty or
  wrong, or names a ticker to update. Costs a handful of requests, so it is the
  right tool for anything a person is actually looking at.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Refresh one security

`security-refresh` does everything for a single symbol in one call: returns, market cap,
fundamentals and statements.

```bash
BASE=https://supabase.rafiki.guru
SRV=<SUPABASE_SERVICE_ROLE_KEY>

curl -sS --max-time 200 -X POST "$BASE/functions/v1/market-refresh" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Content-Type: application/json' \
  -d '{"resource":"security-refresh","symbol":"AAPL","force":true}'
```

A healthy answer:

```json
{"resource":"security-refresh","symbol":"688223.SS","returns":7,
 "marketCap":45288108032,"fundamentals":"updated","statements":"12 rows","refreshed":true}
```

## Why this exists rather than "wait for the backlog"

The statements backlog is **~5 weeks deep** — that resource fetches one security per call, because
the provider does not accept several symbols on `income`/`balance`/`cash` (measured:
`symbolsAsked 50, symbolsAnswered 0`). Without this path the securities someone actually opens would
be *last* in the queue. Three requests on a page a person is looking at fixes that for them.

The app exposes the same thing as an admin-only refresh button on the stock page.

## Which symbol to pass

Pass the symbol the app shows. The function resolves the provider address itself
(`security_provider_symbol`), so `NESN` finds `NESN.SW` and `Samsung` finds `005930.KS`.

If it answers `not covered` for everything, the symbol is probably the Bloomberg spelling rather
than the provider's. Check what the app is storing:

```bash
curl -sS "$BASE/rest/v1/security_symbol?symbol=eq.AAPL&select=*" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Accept-Profile: market'
```

Known bad spellings that come from OpenFIGI's Bloomberg-flavoured `ticker`: `BRK/B` (should be
`BRK-B`), `WALMEX*.MX`, `PE&OLES*.MX`, `6.HK` (Hong Kong pads to four digits: `0006.HK`),
`ESSITYB.ST` (Stockholm share classes take a hyphen: `ESSITY-B.ST`). `security-yahoo-symbols` fixes
these by asking Yahoo for the ISIN's home listing — run that resource rather than editing by hand.

## Expected answers that are NOT failures

| answer | meaning |
|---|---|
| `"skipped": true, "reason": "fresh or in flight"` | the TTL, or a run already going. `force` bypasses the TTL but **not** the in-flight lock — wait a minute |
| `"fundamentals": "not covered"` | the provider genuinely has none for this symbol |
| `"statements": "not covered"` | same; common for thin foreign listings |

## What it deliberately does NOT do

It never writes `statements_missing_at` on failure. A bad request on a button press says nothing
about whether the provider has statements for that security, and marking there would exclude it from
the backlog for 30 days — the defect shape that once cost 8,300 securities.
