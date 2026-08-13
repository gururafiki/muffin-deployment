---
name: market-repair-negative-cache
description:
  Clear securities that were wrongly marked "the provider has nothing for this".
  Use when mega-caps show no sector/industry/fundamentals, when a backlog emptied
  suspiciously fast, or after a provider outage or rate-limit episode. Includes how
  to tell a WRONG mark from an earned one before deleting anything.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Repair a wrongly-set negative cache

`security.*_missing_at` records "we asked and the provider had nothing". It excludes the security
for **30 days**. When it is set wrongly, the security silently disappears from the app and every
count stays plausible.

This has happened twice at scale: 1,369 securities, then ~8,300.

## First: is the mark WRONG, or earned?

Do not skip this. Most marks are correct — yfinance genuinely carries nothing for many thin foreign
listings, and clearing those re-asks a rate-limited provider for an answer already held.

**The test is absurdity, not volume.**

```bash
BASE=https://supabase.rafiki.guru
SRV=<SUPABASE_SERVICE_ROLE_KEY>
cnt() { curl -sS -o /dev/null -D - "$BASE/rest/v1/$1" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" \
  -H 'Accept-Profile: market' -H 'Prefer: count=exact' \
  | sed -n 's/.*content-range: [0-9*-]*\///Ip' | tr -d '\r'; }

for col in industry_missing_at statements_missing_at performance_missing_at fundamentals_missing_at; do
  printf '  %-26s %s of %s US mega-caps\n' "$col" \
    "$(cnt "security?select=security_id&country_iso2=eq.US&market_cap=gt.50000000000&$col=not.is.null")" \
    "$(cnt 'security?select=security_id&country_iso2=eq.US&market_cap=gt.50000000000')"
done
```

**Should be ~0 of ~213.** It read `109 of 213` during the incident. A company worth over $50bn
having no industry is not a provider limitation, it is the bug.

Then name some, so you are looking at companies rather than counts:

```bash
curl -sS "$BASE/rest/v1/security?select=name,industry_missing_at&country_iso2=eq.US&market_cap=gt.50000000000&industry_missing_at=not.is.null&limit=10" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Accept-Profile: market'
```

If you see INTC, PEP, XOM, TXN, REGN, UPS — it is wrong.

## Then: make sure it cannot immediately recur

**Clear only after the fix is deployed**, or the 3-hourly cron re-applies the marks within hours.
All six marking sites are now gated on the endpoint having answered for someone in the run, so a
throttle cannot mark anything — but confirm the deploy that carries that is live.

## Clear it

```bash
DAY=$(date -u +%F)
for col in industry_missing_at statements_missing_at performance_missing_at \
           fundamentals_missing_at prices_missing_at profile_missing_at; do
  before=$(cnt "security?select=security_id&security_type_code=eq.equity&$col=gte.$DAY")
  curl -sS -o /dev/null -X PATCH \
    "$BASE/rest/v1/security?security_type_code=eq.equity&$col=gte.$DAY" \
    -H "apikey: $SRV" -H "Authorization: Bearer $SRV" \
    -H 'Content-Profile: market' -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
    -d "{\"$col\": null}"
  printf '  %-26s cleared %s\n' "$col" "${before:-0}"
done
```

**Scope it by DATE (the incident window) or by ABSURDITY (mega-caps), not "everything".** Clearing
every mark re-asks the provider for thousands of answers it already gave, and the asymmetry only
justifies the ones you have reason to doubt: clearing a legitimate mark costs one re-fetch, keeping
a wrong one costs thirty days.

## Do NOT clear these two

`figi_missing_at` and `local_symbol_missing_at` are keyed on the **ISIN**, not the symbol. A
corrected symbol says nothing about them, and clearing them re-asks a rate-limited provider for an
answer already held. `market.symbol_cache_classification` states which of the nine columns is
symbol-keyed and why.

## Verify

```bash
# the mega-cap check should now read 0
# and the securities should re-enter their backlogs
curl -sS -o /dev/null -D - "$BASE/rest/v1/pending_industry?select=security_id&limit=1" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Accept-Profile: market' -H 'Prefer: count=exact'
```

Then run `market-refresh-routine` to fill them, and `market-health` to confirm.

## If you are writing a repair as a MIGRATION instead

Migrations re-run on every deploy, so a data repair must go through `market.one_shot` or it runs
forever. Clearing `prices_missing_at` on every deploy would permanently defeat the negative cache —
the exact failure the flag exists to prevent, reintroduced as the fix for it.
