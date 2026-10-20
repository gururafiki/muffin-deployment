---
name: market-diagnose
description:
  Work out why a market-data resource is failing or a backlog is stuck. Use when a
  refresh returns an error, a backlog will not shrink, a page shows no numbers, or
  market-verify fails. Starts from the failure modes this pipeline has actually
  had, in the order they are worth checking.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Diagnose a market-data failure

Check these in order. Each one has actually happened, and the earlier ones are cheaper.

**If a Grafana alert named the backlog, start from it.** Replay the rule's own query
(`muffin-grafana-dashboards` § Which alerts are firing) before reading anything else. Of the three
alerts firing on 2026-10-20, two were real stalls weeks old, and the third was a rule I had shipped
that cried wolf.

## 0. Is a deploy running?

Migrations drop and recreate the serving views. A read taken in that window fails with
`42P01 relation does not exist`, a missing column, or a statement timeout — and looks exactly like a
bug. **Three separate failures were diagnosed as bugs before this was recognised.**

```bash
gh run list --workflow="Deploy to Oracle Cloud" --limit 1 --json status
```

If one is in progress, wait and re-check before investigating anything.

## 1. Read the error — the resource now tells you

A failed resource answers **HTTP 200 with `"ok": false`** and the reason.

```bash
curl -sS -X POST "$BASE/functions/v1/market-refresh" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Content-Type: application/json' \
  -d '{"resource":"security-statements","force":true}'
```

**A 410 names the lane that replaced the resource.** The Yahoo company family (profiles,
industries, fundamentals, share stats, officers, quarters, dividends, metrics) left the edge on
2026-10-18, after prices (2026-09-12) and the universe (2026-09-26). Diagnose those in Dagster
(`muffin-dagster-operations`), not here.

**A bare `error code: 502` with no body means the WORKER DIED** — look at memory or a runaway loop,
not at your error handling. Application failures do not look like that any more.

## 2. Is the provider rate-limiting us?

The single most common cause. yfinance under throttle answers **200 with no rows** rather than
erroring, so every count stays plausible.

Signatures, any of which is decisive:

```
YFRateLimitError: Too Many Requests
(provider is RATE-LIMITING — no symbol blamed)
throttledOut: true
```

**Response: stop and wait.** Do not retry harder — every refused request pushes the limit further
out. The resources stop themselves on the first throttle now, so a short run is the system working.

## 3. Is it the cache, the proxy or our client, rather than the provider?

Every edge call reaches its provider through `http-cache`, and openbb calls also pass through a
client library inside `openbb-api`. Each of those layers has hidden a provider's real answer for
weeks.

**Read the cache's line for the URL first.** The log line starts with `$upstream_cache_status`
(`HIT`, `MISS`, `STALE`, `UPDATING`, `BYPASS`, `EXPIRED`):

```bash
ssh muffin 'docker service logs muffin_http-cache --since 2h 2>&1 | grep "price_target?symbol=AAPL" | tail -3'
```

- **`STALE … -> 200` while the provider is failing.** When an entry expires, nginx serves it and
  refreshes it in the background. A refresh answered with a status nginx does not store (400, 403,
  404) leaves the entry in place, so a URL asked regularly keeps its last 200 for as long as the
  provider fails that way. finviz refused openbb-api from about 2026-09-30, and AAPL's cached price
  targets "answered" every run for three weeks, so the resource reported the provider healthy.
  **A control or health probe answered by the cache proves nothing.** Send it with
  `X-Muffin-Cache-Bypass: 1`, which is what the edge's `{ uncached: true }` does.
- **`upstream sent too big header` beside a 502** is nginx's own buffer, not the provider. NSE sent
  4,226 bytes of response headers on 2026-10-03.

**Then ask once past the cache, from inside the overlay.** The header maps to
`proxy_cache_bypass`, so the provider answers this request and a fresh 200 replaces the stored
entry. The cache logs it as `BYPASS`:

```bash
ssh muffin 'docker exec -i $(docker ps -qf name=muffin_muffin-ingest) python -' <<'PY'
import httpx
r = httpx.get("http://http-cache:8080/openbb/api/v1/equity/estimates/price_target",
              params={"symbol": "AAPL", "provider": "finviz"},
              headers={"X-Muffin-Cache-Bypass": "1"}, timeout=60)
print(r.status_code, len(r.json().get("results", [])) if r.status_code == 200 else r.text[:300])
PY
```

**If the provider refuses, ask it from a second client on the same node before blaming the
node.** muffin-ingest imports openbb in-process, so it is the obvious second client. On 2026-10-20
it got 20 AAPL price targets from finviz in the same minute that openbb-api got 403s. openbb-api's
image (built 2026-08-10) carried finvizfinance 1.3.0, whose 2020 User-Agent finviz now refuses;
muffin-ingest carried 1.5.0. Compare the client library in both images:

```bash
ssh muffin 'for s in muffin_openbb-api muffin_muffin-ingest; do echo "$s $(docker exec $(docker ps -qf name=$s) python -c "import importlib.metadata as m; print(m.version(\"finvizfinance\"))" < /dev/null)"; done'
```

The fix for an outdated client is a rebuild that moves only that package (`muffin-deploy`,
§ Pick the path).

## 4. Is the backlog emptying by MARKING rather than by WORKING?

The nastiest failure this pipeline has had, because it reads as success.

```bash
# Marked as unanswerable today, versus classified today
curl -sS -o /dev/null -D - "$BASE/rest/v1/security?select=security_id&security_type_code=eq.equity&industry_missing_at=gte.$(date -u +%F)" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Accept-Profile: market' -H 'Prefer: count=exact'
```

**The decisive check is absurdity, not volume** — a legitimate drain does mark thousands:

```bash
# US mega-caps carrying a negative cache. Should be ~0. It read 109 of 213 during the incident.
curl -sS -o /dev/null -D - \
  "$BASE/rest/v1/security?select=security_id&country_iso2=eq.US&market_cap=gt.50000000000&industry_missing_at=not.is.null" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Accept-Profile: market' -H 'Prefer: count=exact'
```

If mega-caps are marked, use `market-repair-negative-cache`.

## 5. Is the backlog view even satisfiable?

A view can be valid SQL and express something that can never be satisfied, so the resource reports
progress forever while re-fetching the same rows.

The signature: a `where … is null` predicate on a **second** table reached through an *unrestricted*
first join. `pending_industry` had exactly this and re-fetched the same top-300 for weeks —
`classified: 282` every run, 345 securities with an industry against 8,412 with a sector.

```bash
# Anything already classified must NOT still be queued
curl -sS "$BASE/rest/v1/pending_industry?select=security_id&limit=5" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Accept-Profile: market'
# then check those ids for an existing level-2 taxonomy row
```

`stack/supabase/tests/backlogs-are-satisfiable.sql` guards this offline; `market-verify` check 7b
guards it in production.

**Does the handler's done-stamp land?** An UPDATE that matches no row is not an error, so a handler
that stamps its subject done reports success while the subject stays queued. `in-filings` stamped
`security_filer.history_walked_at`, a row it creates only when NSE lists something. Six companies
NSE lists nothing for therefore headed `pending_in_history` from about 2026-10-06 to 10-20, with
289 queued behind them. The signature is the same head in consecutive runs, `ok: true` and nothing
written. Take the queue's head and check that the row the handler updates exists for each. Since
muffin-deployment#453 that handler selects what its stamp matched.

## 6. Is it a grant, or the PostgREST schema cache?

A brand-new table is invisible over the API until PostgREST reloads, and `notify pgrst` is not
reliable. Symptom: `PGRST205`, or `permission denied for table X`.

**The migration tests run as superuser, so they prove nothing about grants.** Check as the role that
actually fails, and remember `anon` has a **3-second statement timeout** while `service_role` has
none — a view that answers service_role in 7s gives anon `57014 canceling statement due to statement
timeout`. That is a performance problem, not RLS.

## 7. Is the symbol simply wrong?

"The provider has no data for this security" is frequently "we asked using the wrong name".
OpenFIGI's `ticker` is the Bloomberg spelling: `BRK/B`, `WALMEX*.MX`, `6.HK` (should be `0006.HK`),
`ESSITYB.ST` (should be `ESSITY-B.ST`). The Dagster symbology ladder's Yahoo rung
(`raw_yahoo_symbol`) asks Yahoo for the ISIN's home listing: backfill the security's
`symbology_subject` partition rather than editing by hand.

## The rule underneath all of this

**Read the whole error, not a truncated one.** `Error getting data for ITGR -> YFR…` reads as an
ordinary symbol failure; the full text was `YFRateLimitError`. A wrong rule was designed on that
misreading and would have negative-cached thousands of innocent securities.
