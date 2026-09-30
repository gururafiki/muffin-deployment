// Verification for market-refresh's provider mapping. Needs a reachable openbb-api
// and NOTHING else — no Supabase, no database, no credentials.
//
//   docker compose -f compose/docker-compose.yml up -d openbb-api
//   deno run --allow-net --allow-env \
//     stack/supabase/functions/market-refresh/check.ts
//
// (or, with no local deno:
//   docker run --rm --network muffin-net -v "$PWD:/w" -w /w denoland/deno:alpine \
//     run --allow-net --allow-env stack/supabase/functions/market-refresh/check.ts )
//
// WHY: the mapping is the part that fails SILENTLY. yfinance's profile carries the
// sub-sector in `industry_category` while `industry` exists and is always null, and a
// symbol the provider spells differently must be written back under OUR key. Both are
// caught here, against the live provider, before deploy.
//
// It used to drive the performance and price resources too; those retired with the
// price family (Dagster owns them), and so did their checks.

import { loadProfiles, openbbFetcher } from './resources.ts'

const BASE = Deno.env.get('OPENBB_API_URL') ?? 'http://localhost:6900'

let failures = 0
const check = (ok: boolean, label: string, detail = '') => {
  console.log(`${ok ? '  PASS' : '  FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`)
  if (!ok) failures++
}

// --- integration: instrument profiles (the real sub-sectors) ------------------
console.log(`\ninstrument-profile against ${BASE}`)
// NESN is deliberately included with its PRICE symbol: it is the one seeded name
// whose provider symbol differs from its display ticker, and it is what caught the
// mapping-back bug (the reply arrives as NESN.SW, our key is NESN).
const PROBE = ['AAPL', 'NVDA', 'JPM', 'XOM', 'PFE', 'NEE', 'PLD', 'BHP', 'SAP']
const PROBE_ENTRIES = [
  ...PROBE.map((symbol) => ({ scopeId: symbol, symbol })),
  { scopeId: 'NESN', symbol: 'NESN.SW' },
]
const profiles = await loadProfiles(openbbFetcher(BASE), PROBE_ENTRIES, new Date())

check(profiles.length === PROBE_ENTRIES.length,
  `all ${PROBE_ENTRIES.length} probe symbols returned a profile`, `got ${profiles.length}`)
check(profiles.some((p) => p.symbol === 'NESN'),
  'a differing price symbol is written back under OUR key (NESN.SW -> NESN)',
  profiles.map((p) => p.symbol).join(','))
// The whole point of this resource: a REAL sub-sector per instrument. yfinance puts
// it in `industry_category`; the `industry` field also exists and is always null,
// which is exactly the kind of silent empty this asserts against.
check(profiles.every((p) => p.industry && p.industry.length > 1),
  'every profile carries a non-empty industry (the sub-sector)',
  profiles.filter((p) => !p.industry).map((p) => p.symbol).join(', ') || 'all present')
check(profiles.every((p) => p.provider_sector), 'every profile carries a provider sector')
check(profiles.every((p) => p.country), 'every profile carries a country')
check(profiles.every((p) => (p.market_cap ?? 0) > 0), 'every profile carries a market cap')
for (const p of profiles.slice(0, 4)) {
  console.log(`  ${p.symbol.padEnd(5)} ${String(p.provider_sector).padEnd(20)} ${p.industry}`)
}

console.log(failures === 0 ? '\nOK' : `\n${failures} FAILED`)
if (failures > 0) Deno.exit(1)
