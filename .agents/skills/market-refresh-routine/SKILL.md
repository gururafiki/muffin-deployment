---
name: market-refresh-routine
description:
  Drain the market-data backlogs by hand, PACED so it does not trip the provider's
  rate limit. Use when someone asks to "refresh the market data", "catch the
  backlogs up", "ingest what is missing", or after adding funds. Do NOT use for a
  single security (market-refresh-security) or a new ETF (market-add-fund).
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Refresh the market data

The cron already does this eight times a day, paced. Run it by hand only when you want it
**sooner** — after adding funds, after clearing negative caches, or when a backlog is visibly deep.

## The one thing that matters

**Draining faster than yfinance allows drains LESS.** Measured 2026-08-13: firing the resources back
to back tripped the rate limit within three cycles, and — before the guards existed — recorded
~8,300 securities as permanently unanswerable, including INTC, PEP, XOM and REGN. The guards make
that impossible now, but a throttled run still does less work than a paced one, because every
refused batch is a batch not drained.

So: **45 s between resources, 90 s between cycles, back off 6 minutes on any throttle signature.**

## Setup

```bash
BASE=https://supabase.rafiki.guru          # the PUBLIC supabase host
SRV=<SUPABASE_SERVICE_ROLE_KEY>            # from `gh secret list`; writes are admin-only
call() {                                    # $1 = resource, $2… = extra JSON fields
  curl -sS --max-time 250 -X POST "$BASE/functions/v1/market-refresh" \
    -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Content-Type: application/json' \
    -d "{\"resource\":\"$1\",\"force\":true${2:+,$2}}"
}
```

`force` bypasses the TTL and the error backoff but **not** the in-flight lock, and is service-role
only — the anon key is public and a public cache-buster is a free way to hammer the provider.

## The order, and why it is this order

Each one unlocks the next. Running them out of order wastes a pass.

```
security-yahoo-symbols    resolves an ISIN to its HOME-market symbol — the GATE.
security-local-symbols    OpenFIGI, a different provider, so it does not compete for the limit.
security-profiles         gives a security its SECTOR.
security-industries       needs a sector, so it only has work after profiles ran.
security-prices           daily bars, incremental from the last stored date.
security-performance      returns, computed from the bars.
security-fundamentals     P/E, margins, market cap.
security-statements       income/balance/cash — ONE security per call, so it is the slow one.
```

## Running it

```bash
for cycle in 1 2 3 4 5 6; do
  throttled=0
  for r in security-yahoo-symbols security-local-symbols security-profiles security-industries \
           security-prices security-performance security-fundamentals security-statements; do
    out=$(call "$r")
    echo "$r: $out"
    case "$out" in *RateLimit*|*"Too Many Requests"*|*RATE-LIMITING*) throttled=1;; esac
    sleep 45
  done
  [ "$throttled" = 1 ] && { echo "throttled — backing off"; sleep 360; } || sleep 90
done
```

## Reading the answer

A run reports counts, and the counts mean different things:

| field | meaning |
|---|---|
| `written` / `classified` / `resolved` | real progress |
| `noProfile` / `noIndustry` / `unresolved` | the provider ANSWERED and had nothing — also progress, the backlog shrinks |
| `batchesFailed` | requests that threw |
| `throttledOut: true` | the run stopped early on a rate limit. Not an error; try later |
| `"ok": false` | the resource failed and is telling you why in `error` |

**A failed resource answers HTTP 200 with `"ok": false`.** It used to answer 502 and the proxy
replaced the body, so the reason never arrived. A bare 502 now means a genuinely dead worker.

## Do not

- **Do not raise the page size to go faster.** The limit is requests per unit *time*, not per run.
  `security-industries` uses 30 calls of its 90-second budget; raising its page raises calls per run
  and trips the limit sooner, buying nothing. The only optimisation that works is fewer requests
  *per security* — which is why statements is slow and cannot simply be batched (measured:
  `symbolsAsked 50, symbolsAnswered 0`).
- **Do not run this while a deploy is in progress.** Migrations drop and recreate the serving views;
  a read taken in that window fails with `42P01` or a statement timeout and looks like a bug.

## Checking progress

```bash
for v in pending_yahoo_symbol pending_local_symbol pending_profile pending_industry \
         pending_prices pending_performance pending_fundamentals pending_statements; do
  printf '%-24s %s\n' "$v" "$(curl -sS -o /dev/null -D - \
    "$BASE/rest/v1/$v?select=security_id&limit=1" \
    -H "apikey: $SRV" -H "Authorization: Bearer $SRV" \
    -H 'Accept-Profile: market' -H 'Prefer: count=exact' \
    | sed -n 's/.*content-range: [0-9*-]*\///Ip' | tr -d '\r')"
done
```

**A backlog that shrinks is not automatically a backlog that is working.** It can empty by MARKING
securities unanswerable instead of by fetching them. If a count drops while `written`/`classified`
stay at 0, stop and use `market-diagnose`.
