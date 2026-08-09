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
// WHY: the mapping is the part that fails SILENTLY. If finviz renames a sector we
// drop it; if it switches fraction->percent every number is 100x off but still looks
// plausible. Both are caught here, against the live provider, before deploy.

import {
  FINVIZ_SECTOR_IDS,
  loadPrices,
  loadProfiles,
  PRICE_WINDOW_DAYS,
  openbbFetcher,
  RESOURCES,
  returnsFor,
  toPercent,
} from './resources.ts'

const BASE = Deno.env.get('OPENBB_API_URL') ?? 'http://localhost:6900'

let failures = 0
const check = (ok: boolean, label: string, detail = '') => {
  console.log(`${ok ? '  PASS' : '  FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`)
  if (!ok) failures++
}

// --- unit: the fraction -> percent conversion --------------------------------
console.log('toPercent')
check(toPercent(-0.0366) === -3.66, 'fraction -0.0366 becomes -3.66%', `got ${toPercent(-0.0366)}`)
check(toPercent(0.2861) === 28.61, 'fraction 0.2861 becomes 28.61%', `got ${toPercent(0.2861)}`)
check(toPercent(null) === null, 'null passes through')
check(toPercent('12') === null, 'a string is not silently coerced')

// --- unit: return maths on a hand-built series -------------------------------
// Uses a FIXED series and a fixed "now" so the arithmetic is checked exactly,
// independent of whatever the market did today.
console.log('\nreturnsFor')
{
  const now = new Date('2026-08-09T00:00:00Z')
  const series = [
    { date: '2025-06-01', close: 80 }, //  1y anchor (last bar <= 2025-08-09)
    { date: '2025-12-30', close: 100 }, // ytd anchor (last close of 2025)
    { date: '2026-06-01', close: 110 },
    { date: '2026-08-01', close: 120 }, // 1d anchor (the previous bar)
    { date: '2026-08-08', close: 132 }, // latest
  ]
  const r = returnsFor(series, now)
  check(r['1d'] === 10, '1d uses the PREVIOUS BAR, not a date lookback', `got ${r['1d']} (132/120)`)
  check(r['ytd'] === 32, 'ytd anchors on the last close of last year', `got ${r['ytd']} (132/100)`)
  check(r['1y'] === 65, '1y picks the last bar at or before the anchor', `got ${r['1y']} (132/80)`)
  check(!('5y' in r), 'a period the series cannot reach is omitted, not zero')
  check(Object.keys(returnsFor([{ date: '2026-08-08', close: 1 }], now)).length === 0,
    'a one-bar series yields nothing rather than dividing by itself')
}

// --- integration: the live provider ------------------------------------------
console.log(`\nsector-performance against ${BASE}`)
const { rows, unmapped } = await RESOURCES['sector-performance'].load({
  fetcher: openbbFetcher(BASE),
  now: new Date(),
})

check(unmapped.length === 0, 'every provider sector label is mapped', unmapped.join(', ') || 'none')

const ids = new Set(rows.map((r) => r.scope_id))
check(
  ids.size === Object.keys(FINVIZ_SECTOR_IDS).length,
  `all ${Object.keys(FINVIZ_SECTOR_IDS).length} sectors produced rows`,
  `got ${ids.size}`,
)

// The DB CHECK constraints will reject anything outside these vocabularies, so a
// drift here would fail every deploy's refresh rather than this script.
const PERIODS = new Set(['1d', '1w', '1m', '3m', '6m', 'ytd', '1y', '3y', '5y', '10y'])
check(rows.every((r) => PERIODS.has(r.period)), 'every period is in the DB vocabulary')
check(rows.every((r) => r.scope === 'sector'), 'every row is scoped to sector')

// Percent, not fraction: real sector moves are ~0.1-60%, never <0.001 across the
// board. A fraction/percent regression collapses everything toward zero.
const magnitudes = rows.map((r) => Math.abs(r.change_pct ?? 0))
const maxMag = Math.max(...magnitudes)
check(maxMag > 1, 'values are percent, not fractions', `largest |change| = ${maxMag}`)
check(maxMag < 500, 'values are not double-scaled', `largest |change| = ${maxMag}`)

check(
  rows.every((r) => new Date(r.stale_after) > new Date(r.as_of)),
  'stale_after is always after as_of',
)

console.log(`\n${rows.length} rows, ${ids.size} sectors`)
const oneYear = rows.filter((r) => r.period === '1y').sort((a, b) => (b.change_pct ?? 0) - (a.change_pct ?? 0))
for (const r of oneYear) console.log(`  ${r.scope_id.padEnd(24)} 1y ${String(r.change_pct).padStart(8)}%`)

// --- integration: country performance from batched price history --------------
// The universe is normally read from `market.countries`; here it is inlined so the
// check needs no database. Keep it in step with 04-market-reference.sql.
console.log(`\ncountry-performance against ${BASE}`)
const UNIVERSE = [
  ['US', 'IVV'], ['CA', 'EWC'], ['MX', 'EWW'], ['GB', 'EWU'], ['DE', 'EWG'],
  ['FR', 'EWQ'], ['CH', 'EWL'], ['JP', 'EWJ'], ['AU', 'EWA'], ['IN', 'INDA'],
  ['KR', 'EWY'], ['CN', 'MCHI'], ['HK', 'EWH'], ['TW', 'EWT'], ['BR', 'EWZ'],
  ['CL', 'ECH'], ['SA', 'KSA'], ['ZA', 'EZA'], ['AE', 'UAE'],
].map(([scopeId, symbol]) => ({ scopeId, symbol }))

const country = await RESOURCES['country-performance'].load({
  fetcher: openbbFetcher(BASE),
  now: new Date(),
  universe: async () => UNIVERSE,
})

check(country.unmapped.length === 0, 'every country ETF returned a usable series',
  country.unmapped.join(', ') || 'none')
const countryIds = new Set(country.rows.map((r) => r.scope_id))
check(countryIds.size === UNIVERSE.length, `all ${UNIVERSE.length} countries produced rows`,
  `got ${countryIds.size}`)
check(country.rows.every((r) => PERIODS.has(r.period)), 'every period is in the DB vocabulary')
check(country.rows.every((r) => r.scope === 'country'), 'every row is scoped to country')
check(country.rows.some((r) => r.period === '5y'),
  'multi-year periods exist here (they do not for sectors)')
const countryMax = Math.max(...country.rows.map((r) => Math.abs(r.change_pct ?? 0)))
check(countryMax > 1 && countryMax < 1000, 'country values are plausible percents',
  `largest |change| = ${countryMax}`)

console.log(`\n${country.rows.length} rows, ${countryIds.size} countries`)
const c1y = country.rows.filter((r) => r.period === '1y').sort((a, b) => (b.change_pct ?? 0) - (a.change_pct ?? 0))
for (const r of c1y) console.log(`  ${r.scope_id}  1y ${String(r.change_pct).padStart(8)}%`)

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

// --- integration: instrument performance --------------------------------------
console.log(`\ninstrument-performance against ${BASE}`)
const instruments = await RESOURCES['instrument-performance'].load({
  fetcher: openbbFetcher(BASE),
  now: new Date(),
  universe: async () => PROBE.map((symbol) => ({ scopeId: symbol, symbol })),
})
check(instruments.unmapped.length === 0, 'every probe symbol produced a series',
  instruments.unmapped.join(', ') || 'none')
check(new Set(instruments.rows.map((r) => r.scope_id)).size === PROBE.length,
  `all ${PROBE.length} instruments produced rows`)
check(instruments.rows.every((r) => r.scope === 'instrument'), 'every row is scoped to instrument')
check(instruments.rows.every((r) => PERIODS.has(r.period)), 'every period is in the DB vocabulary')

// --- integration: the price series behind the stock-page chart ----------------
console.log(`\ninstrument-prices against ${BASE}`)
const prices = await loadPrices(openbbFetcher(BASE), PROBE_ENTRIES, new Date())
check(prices.unmapped.length === 0, 'every probe symbol returned a series',
  prices.unmapped.join(', ') || 'none')
const perSymbol = new Map<string, number>()
for (const r of prices.rows) perSymbol.set(r.symbol, (perSymbol.get(r.symbol) ?? 0) + 1)
check(perSymbol.size === PROBE_ENTRIES.length, `all ${PROBE_ENTRIES.length} symbols have bars`,
  `got ${perSymbol.size}`)
// ~400 calendar days is ~280 trading bars; well under that means a truncated series.
const fewest = Math.min(...perSymbol.values())
check(fewest > 200, 'each series has enough bars to draw a 1Y chart', `fewest = ${fewest}`)
check(prices.rows.every((r) => /^\d{4}-\d{2}-\d{2}$/.test(r.date)), 'dates are plain ISO days')
check(prices.rows.every((r) => Number.isFinite(r.close) && r.close > 0), 'every close is positive')
// Written under OUR key, never the provider's.
check(perSymbol.has('NESN') && !perSymbol.has('NESN.SW'),
  'prices are keyed by our symbol, not the provider\'s')
const oldest = prices.rows.reduce((m, r) => (r.date < m ? r.date : m), '9999')
const windowStart = new Date(Date.now() - PRICE_WINDOW_DAYS * 86400000).toISOString().slice(0, 10)
check(oldest >= windowStart, 'nothing older than the declared window', `oldest ${oldest} >= ${windowStart}`)
console.log(`  ${prices.rows.length} bars across ${perSymbol.size} symbols`)

console.log(failures === 0 ? '\nOK' : `\n${failures} FAILED`)
if (failures > 0) Deno.exit(1)
