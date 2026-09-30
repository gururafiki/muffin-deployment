---
name: market-add-fund
description:
  Add an ETF to the tracked universe and ingest its holdings end to end. Use when
  someone asks to track a new fund, add coverage for a sector/country/theme, or
  wonders why some company is missing. Includes the check that stops you adding a
  fund that can never be ingested.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Add a fund to the universe

The stock universe **is** the union of the tracked funds' holdings. Coverage grows by adding funds,
never by scanning exchanges. Adding one is a ROW, not a deploy.

## Step 1 — check the fund can be ingested AT ALL

Do this first. It is the difference between adding coverage and adding a resource that fails on
every run forever.

```bash
curl -sS "https://www.sec.gov/files/company_tickers_mf.json" \
  -H 'User-Agent: yourname you@example.com' \
  | python3 -c "
import sys, json
want = {'IWM','SMH','SLV'}                      # <- the tickers you are considering
d = json.load(sys.stdin)
rows = d['data'] if isinstance(d, dict) else d
found = {r[3].upper() for r in rows if len(r) > 3 and r[3]}
for w in want:
    print(f'  {w:6} {\"files N-PORT\" if w in found else \"NOT AN N-PORT FILER — cannot ingest\"}')"
```

**Four kinds of fund are structurally unreachable** and no retry helps:

| | why |
|---|---|
| SLV | a commodity **trust**, not a 1940-Act fund |
| USO, DBC | commodity **pools** — they file 10-K |
| MDY | a **unit investment trust** — UITs file no N-PORT |
| non-US UCITS | not SEC-registered at all |

A fund missing from `company_tickers_mf.json` may also simply be **liquidated** — SEC drops delisted
funds from that file. Confirm with EDGAR full-text search before concluding anything:
`efts.sec.gov/LATEST/search-index?q="<seriesId>"&forms=NPORT-P`.

## Step 2 — add the row

In Supabase Studio, `market.tracked_fund`:

```sql
insert into market.tracked_fund (symbol, name, kind, represents_code) values
  ('XLE', 'Energy Select Sector SPDR', 'sector', 'energy');
```

- `kind` — `sector`, `country`, `group`, or `other`
- `represents_code` — **only** for a fund that IS its category. `derive-classifications` joins on
  it, so a sector SPDR's holdings become that sector's constituents. Leave it null for a style,
  thematic or fixed-income fund: holding a stock is not evidence that the stock IS that style.

The seed migration uses `on conflict do nothing`, so a Studio edit survives every redeploy.

## Step 3 — let Dagster ingest it

There is nothing to call. The edge `fund-holdings` resource retired on 2026-09-26 and answers 410.
Dagster's `new_nport_filings` sensor finds the fund's newest filing (EDGAR full-text search by
series; a new fund's CIK and series come from SEC's daily directory) and adds a partition.
`raw_nport_filing` fetches it at once, and `discovered_security` and `fund_holding` follow in the
same run. The symbology ladder then resolves the ISINs it introduced.

To classify the new holdings now rather than at the next daily run:

```bash
BASE=https://supabase.rafiki.guru
SRV=<SUPABASE_SERVICE_ROLE_KEY>
curl -sS --max-time 250 -X POST "$BASE/functions/v1/market-refresh" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Content-Type: application/json' \
  -d '{"resource":"derive-classifications","force":true}'
```

Then let the backlogs do the rest: sectors, industries and fundamentals pick the new securities up
on their own. Use `market-refresh-routine` if you want that sooner than the cron.

## Step 4 — confirm it actually landed

```bash
curl -sS -D - -o /dev/null "$BASE/rest/v1/fund_holdings?fund_symbol=eq.XLE&select=as_of&limit=1" \
  -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H 'Accept-Profile: market' \
  -H 'Prefer: count=exact' | grep -i content-range
```

The count after the `/` is the fund's holdings. If it is 0, look at the lane
(`muffin-dagster-operations`): did the sensor add a `nport_filing` partition for the fund, and did
its `raw_nport_filing` run succeed? A style fund often adds few securities and many holdings — it
mostly deepens coverage of names other funds hold. IWM was the exception: 1,922 small caps nothing
else held.

## What to expect

- **Weights do not sum to 100.** EWT's own filing sums to 110.38. Anything drawing a donut must
  renormalise.
- **N-PORT lags ~60 days**, so holdings can be up to ~4 months old. Always show `as_of`; never imply
  the weights are live.
- **A bond fund adds bonds.** AGG brought 13,266 securities and made the table majority non-equity.
  That is correct and handled — every serving view and backlog filters `security_type_code = 'equity'`.
