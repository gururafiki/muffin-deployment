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
  -d '{"resource":"security-profiles","force":true}'
```

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

## 3. Is the backlog emptying by MARKING rather than by WORKING?

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

## 4. Is the backlog view even satisfiable?

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

## 5. Is it a grant, or the PostgREST schema cache?

A brand-new table is invisible over the API until PostgREST reloads, and `notify pgrst` is not
reliable. Symptom: `PGRST205`, or `permission denied for table X`.

**The migration tests run as superuser, so they prove nothing about grants.** Check as the role that
actually fails, and remember `anon` has a **3-second statement timeout** while `service_role` has
none — a view that answers service_role in 7s gives anon `57014 canceling statement due to statement
timeout`. That is a performance problem, not RLS.

## 6. Is the symbol simply wrong?

"The provider has no data for this security" is frequently "we asked using the wrong name".
OpenFIGI's `ticker` is the Bloomberg spelling: `BRK/B`, `WALMEX*.MX`, `6.HK` (should be `0006.HK`),
`ESSITYB.ST` (should be `ESSITY-B.ST`). Run `security-yahoo-symbols`, which asks Yahoo for the
ISIN's home listing, rather than editing by hand.

## The rule underneath all of this

**Read the whole error, not a truncated one.** `Error getting data for ITGR -> YFR…` reads as an
ordinary symbol failure; the full text was `YFRateLimitError`. A wrong rule was designed on that
misreading and would have negative-cached thousands of innocent securities.
