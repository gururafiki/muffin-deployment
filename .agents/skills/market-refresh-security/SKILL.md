---
name: market-refresh-security
description:
  Refresh ONE security now, by queueing its Dagster company-lane run (profile, fundamentals,
  statements). Use when someone says a specific stock page looks stale, empty or
  wrong, or names a ticker to update. Costs a handful of requests, so it is the
  right tool for anything a person is actually looking at.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Refresh one security

**Since 2026-10-18 `security-refresh` fetches nothing itself.** It queues the security's partition
of the Dagster company lane (`yahoo_companies`) with `force: true`, which asks Yahoo for the summary
and the annual and quarterly statements whatever is already held, then writes the profile, officers,
fundamentals, share stats, estimates, classification and statements. The run queues behind the
`yfinance` pool like any other and lands in a few minutes. Returns are not part of it: the price
lane computes them nightly, and `market.performance` is a view over them.

```bash
BASE=https://supabase.rafiki.guru
SRV=<SUPABASE_SERVICE_ROLE_KEY>

curl -sS --max-time 60 -X POST "$BASE/functions/v1/market-refresh" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Content-Type: application/json' \
  -d '{"resource":"security-refresh","symbol":"AAPL"}'
```

A healthy answer names the run:

```json
{"resource":"security-refresh","symbol":"AAPL","queued":true,"runId":"47a63e88-0b60-4576-8934-21ed6782ff80"}
```

Then read what the run wrote with `muffin-dagster-operations` (`scripts/run_events.py` over the run
id). That AAPL run, on 2026-10-18, answered the summary, forced the statements
(`statements_reason_forced=1`) and wrote 29 statement rows with `throttled=0`. The run carries
`dagster/max_runtime=600` and `muffin/reason=refresh button: AAPL`.

## Why this exists rather than "wait for the rotation"

The company lane visits each company once a week (a seventh of the universe a day from 03:30 UTC),
and fetches statements only after an earnings date or at 90 days. A page someone is looking at should
not wait for that. The app exposes the same call as an admin-only Refresh button on the stock page,
which says "queued" and that the figures arrive minutes later.

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
`ESSITYB.ST` (Stockholm share classes take a hyphen: `ESSITY-B.ST`). The Dagster symbology ladder
fixes these: its Yahoo rung (`raw_yahoo_symbol`) asks Yahoo for the ISIN's home listing. The rung is
an operator backfill today, so backfill the security's `symbology_subject` partition rather than
editing by hand (umbrella `docs/deferred/2026-09-24-the-yahoo-rung-is-an-operator-backfill.md`).

## Expected answers that are NOT failures

| answer | meaning |
|---|---|
| `"skipped": true, "reason": "fresh or in flight"` | another press in the last minute (the TTL is 1 minute). Wait a minute |
| `"queued": false, "reason": …` | nothing was launched: the symbol resolves to no security, or Dagster refused the launch, and `reason` says which |

## What it deliberately does NOT do

It never marks a security as having no data. A button press says nothing about what a provider holds,
and the company lane records Yahoo's answers itself. It also does not move the rotation: a hand
launch does not change which companies the next day's schedule visits.
