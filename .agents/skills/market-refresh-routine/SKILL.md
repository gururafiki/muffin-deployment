---
name: market-refresh-routine
description:
  Drain the edge function's remaining market-data backlogs (SEC's XBRL, filing
  history and segments) by hand, PACED so it does not trip a provider's rate
  limit. Use when someone asks to "refresh the market data", "catch the backlogs up"
  or "ingest what is missing". Yahoo company data, prices and the universe are Dagster
  lanes since 2026-10-18 (muffin-dagster-operations). Do NOT use for a single security
  (market-refresh-security) or a new ETF (market-add-fund).
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Refresh the market data

**Most of what this used to drain is not on the edge any more.** Since 2026-10-18 Yahoo's company
data (profiles, industries, fundamentals, share stats and estimates, officers, statements,
dividends) is the Dagster company lane's, a seventh of the universe a day from 03:30 UTC, and the
metric derivation runs at :17 and :47. Prices, returns and FX moved on 2026-09-12, the universe on
2026-09-26, and Tiingo's corporate actions and SEC's openbb statements (`security-statements`)
retired on 2026-10-25. Their old resource names answer **410** with the lane that replaced them. To get one
company sooner, press Refresh on its stock page, or launch `yahoo_companies` for chosen partitions
with `--op-config raw_yahoo_company.force=true` (`muffin-dagster-operations`).

What remains here are SEC's backlogs, each on its own pg_cron job. Run them by hand only when you
want them **sooner**: after clearing negative caches, or when a backlog is visibly deep.

## The one thing that matters

**Draining faster than a provider allows drains LESS.** Measured on yfinance, 2026-08-13: firing the
resources back to back tripped the rate limit within three cycles, and — before the guards existed —
recorded ~8,300 securities as permanently unanswerable, including INTC, PEP, XOM and REGN. The guards make
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

## What is left to drain

```
security-xbrl             SEC company facts, the quarterly depth; bounded by MEMORY, so pace it.
security-filing-history   SEC submissions: a filer's whole filing index, and its SIC code.
security-segments         one filing's XBRL instance per row, breadth-first across companies.
```

## Running it

```bash
for cycle in 1 2 3 4 5 6; do
  throttled=0
  for r in security-xbrl security-filing-history security-segments; do
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
| `written` / `fromSec` | real progress |
| `secNone` / `noSegments` / `noInstance` | the provider ANSWERED and had nothing, recorded so it is not re-asked — also progress, the backlog shrinks |
| `tooLarge` | a filing over the size gate, refused rather than allowed to kill the worker |
| `batchesFailed` | requests that threw |
| `throttledOut: true` | the run stopped early on a rate limit. Not an error; try later |
| `"ok": false` | the resource failed and is telling you why in `error` |

**A failed resource answers HTTP 200 with `"ok": false`.** It used to answer 502 and the proxy
replaced the body, so the reason never arrived. A bare 502 now means a genuinely dead worker.

## Do not

- **Do not raise the page size to go faster.** The limit is requests per unit *time*, not per run.
  `security-industries` (retired 2026-10-18) used 30 calls of its 90-second budget; raising its page
  raised calls per run and tripped the limit sooner, buying nothing. The only optimisation that works is fewer requests
  *per security* — which is why statements is slow and cannot simply be batched (measured:
  `symbolsAsked 50, symbolsAnswered 0`).
- **Do not run this while a deploy is in progress.** Migrations drop and recreate the serving views;
  a read taken in that window fails with `42P01` or a statement timeout and looks like a bug.

## Checking progress

```bash
for v in pending_xbrl pending_filing_history pending_segments; do
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
