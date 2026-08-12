// The market-refresh logic that can be checked with NO network and NO database.
//
// WHY THIS EXISTS SEPARATELY FROM `check.ts`. That file drives a real openbb-api, so it cannot run
// in CI and only runs when someone remembers to. Everything here is pure, so it runs on every PR —
// which is the difference between a rule that holds and a rule that held once.
//
// Every assertion below is a defect that REACHED PRODUCTION and returned HTTP 200 while doing so.
// None of them would have been caught by a floor, a count, or an error handler.
//
//   deno run stack/supabase/functions/market-refresh/logic-check.ts

import {
  barFrom,
  dedupeBy,
  fetchWithIsolation,
  firstComparableIndex,
  returnsFor,
  symbolList,
  toPercent,
  type Bar,
} from './resources.ts'
import { pickHomeListing } from './yahoo.ts'
import { venuesFromRows, hasLocalExchange, pickLocalSymbol } from './exchanges.ts'

let failures = 0
const check = (ok: boolean, label: string, detail = '') => {
  if (!ok) failures++
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
}

// ── a close of zero is not a price ───────────────────────────────────────────
// Shipped: 1,078 of 20,399 performance rows at exactly -100%, i.e. 154 securities each showing
// -100% on all seven periods including `1d`. `Number.isFinite(0)` is true, so a zero bar was
// accepted, and `returnsFor` guarded only the denominator.
console.log('\nbarFrom — a close of zero is not a price')
check(barFrom({ symbol: 'X', date: '2026-01-02', close: 0 }, 'X') === null,
  'a zero close is rejected')
check(barFrom({ symbol: 'X', date: '2026-01-02', close: -3 }, 'X') === null,
  'a negative close is rejected')
check(barFrom({ symbol: 'X', date: '2026-01-02', close: 'abc' }, 'X') === null,
  'a non-numeric close is rejected')
check(barFrom({ symbol: 'X', date: '', close: 5 }, 'X') === null, 'a missing date is rejected')
check(barFrom({ date: '2026-01-02', close: 5 }, 'FALLBACK')?.symbol === 'FALLBACK',
  'a single-symbol response falls back to the requested symbol')
check(barFrom({ symbol: 'X', date: '2026-01-02T00:00:00', close: 5 }, 'X')?.bar.date === '2026-01-02',
  'a timestamp is truncated to a plain ISO day')

// The end-to-end shape of that bug: a trailing zero bar must not make every period -100%.
{
  const now = new Date('2026-08-09T00:00:00Z')
  const withZero: Bar[] = [
    { date: '2025-06-01', close: 80 },
    { date: '2025-12-30', close: 100 },
    { date: '2026-08-08', close: 0 },
  ]
  const r = returnsFor(withZero, now)
  check(!Object.values(r).some((v) => v === -100),
    'a zero LATEST close cannot produce -100% across every period',
    `got ${JSON.stringify(r)}`)
}

// ── a discontinuity is not a market move ─────────────────────────────────────
// Shipped: AMRM.TA +9453.7% and ISHO.TA +8946.9%, both quoted in ILA and both jumping ~100x on the
// SAME day (2026-05-18) — Yahoo switching Tel Aviv quotes from shekels to agorot. Measured over all
// 40 securities returning >= +300%: the largest legitimate one-day move was 2.04x and the smallest
// illegitimate one 6.0x, so the two populations do not overlap.
console.log('\nfirstComparableIndex — a unit change is not a market move')
{
  const smooth: Bar[] = [
    { date: '2026-01-01', close: 100 },
    { date: '2026-01-02', close: 128 }, // SNDK's real biggest day was 1.28x
    { date: '2026-01-03', close: 150 },
  ]
  check(firstComparableIndex(smooth) === 0, 'a smooth series is comparable throughout')

  const redenominated: Bar[] = [
    { date: '2026-01-01', close: 41.83 },
    { date: '2026-01-02', close: 4040 }, // AMRM.TA, 96.6x, ILS -> agorot
    { date: '2026-01-03', close: 4100 },
  ]
  check(firstComparableIndex(redenominated) === 1, 'the bar after a ~100x jump starts a new regime')

  const collapsed: Bar[] = [
    { date: '2026-01-01', close: 4000 },
    { date: '2026-01-02', close: 40 }, // the same thing in reverse
    { date: '2026-01-03', close: 41 },
  ]
  check(firstComparableIndex(collapsed) === 1, 'a 100x FALL is caught too, not just a rise')
}
{
  // Per PERIOD, not per symbol: a break 30 days ago must not discard today's 1d.
  const now = new Date('2026-08-09T00:00:00Z')
  const series: Bar[] = [
    { date: '2025-06-01', close: 80 },   // 1y anchor — BEFORE the break
    { date: '2025-12-30', close: 100 },  // ytd anchor — BEFORE the break
    { date: '2026-07-10', close: 10000 }, // the break: 100x
    { date: '2026-08-01', close: 10500 },
    { date: '2026-08-08', close: 11000 }, // latest
  ]
  const r = returnsFor(series, now)
  check(!('1y' in r), '1y spans the break and is OMITTED, not reported')
  check(!('ytd' in r), 'ytd spans the break and is omitted')
  check(r['1d'] !== undefined, '1d is AFTER the break and survives', `got ${r['1d']}`)
  check(Math.abs((r['1d'] ?? 0) - 4.7619) < 0.001, '1d is still computed correctly', `got ${r['1d']}`)
  check(!Object.values(r).some((v) => v > 1000),
    'no period reports the fabricated ~10,000% move', `got ${JSON.stringify(r)}`)
}

// ── the return maths itself ──────────────────────────────────────────────────
console.log('\nreturnsFor — anchors')
{
  const now = new Date('2026-08-09T00:00:00Z')
  const series: Bar[] = [
    { date: '2025-06-01', close: 80 },
    { date: '2025-12-30', close: 100 },
    { date: '2026-06-01', close: 110 },
    { date: '2026-08-01', close: 120 },
    { date: '2026-08-08', close: 132 },
  ]
  const r = returnsFor(series, now)
  check(r['1d'] === 10, '1d uses the PREVIOUS BAR, not a date lookback', `got ${r['1d']}`)
  check(r['ytd'] === 32, 'ytd anchors on the last close of last year', `got ${r['ytd']}`)
  check(r['1y'] === 65, '1y picks the last bar at or before the anchor', `got ${r['1y']}`)
  check(!('5y' in r), 'a period the series cannot reach is omitted, not zero')
  check(Object.keys(returnsFor([{ date: '2026-08-08', close: 1 }], now)).length === 0,
    'a one-bar series yields nothing rather than dividing by itself')
}

// ── symbols are not URL-safe ─────────────────────────────────────────────────
// Shipped: `BRK/B` 400s and takes its whole batch of 20 with it; `PE&OLES*.MX` unencoded ENDS the
// symbol parameter and silently truncates the request, which still returns 200.
console.log('\nsymbolList — real tickers are not URL-safe')
check(symbolList(['AAPL', 'MSFT']) === 'AAPL,MSFT', 'ordinary symbols are untouched')
check(symbolList(['BRK/B']) === 'BRK%2FB', 'a slash is encoded (it 400s the whole batch raw)')
check(symbolList(['PE&OLES*.MX']).indexOf('&') === -1,
  'an ampersand cannot terminate the parameter', symbolList(['PE&OLES*.MX']))
check(symbolList(['A', 'B']).split(',').length === 2, 'the comma SEPARATOR stays literal')
check(symbolList(['NESN.SW']) === 'NESN.SW', 'a dot suffix is not mangled')
check(symbolList(['005930.KS', 'BP/.L']) === '005930.KS,BP%2F.L',
  'a mixed batch encodes only what needs it')

// ── fraction vs percent ──────────────────────────────────────────────────────
console.log('\ntoPercent')
check(toPercent(-0.0366) === -3.66, 'a fraction becomes a percent', `got ${toPercent(-0.0366)}`)
check(toPercent(null) === null, 'a missing value stays missing')
check(toPercent('0.5') === null, 'a string is not silently coerced')

// ── the same conflict key twice fails the WHOLE statement ────────────────────
// Shipped: `security-industries` returned a bare 502 on any page big enough to contain a security
// classified into two sectors. Postgres refuses `ON CONFLICT DO UPDATE` when one statement carries
// the same key twice (SQLSTATE 21000) — it fails the batch, not the row. Third occurrence of this
// shape in the pipeline: fund holdings and the sector views both had to dedupe already.
console.log('\ndedupeBy — one row per conflict key')
{
  const writes = [
    { security_id: 'a', node_id: 'n1', source_code: 'yfinance', v: 1 },
    { security_id: 'a', node_id: 'n1', source_code: 'yfinance', v: 2 },
    { security_id: 'b', node_id: 'n1', source_code: 'yfinance', v: 3 },
  ]
  const out = dedupeBy(writes, (w) => `${w.security_id}|${w.node_id}|${w.source_code}`)
  check(out.length === 2, 'a repeated conflict key collapses to one row', `got ${out.length}`)
  check(out.find((w) => w.security_id === 'a')?.v === 2, 'last write wins')
  check(dedupeBy([], (x: { id: string }) => x.id).length === 0, 'an empty list stays empty')
  const keys = out.map((w) => `${w.security_id}|${w.node_id}|${w.source_code}`)
  check(new Set(keys).size === keys.length, 'no duplicate key survives — the actual DB constraint')
}

// ── one dead symbol must not kill nineteen good ones ─────────────────────────
// The most repeated failure in this pipeline: group-performance on FM, security-profiles on foreign
// listings, and security-industries on the Bloomberg spellings that 400 even once encoded. Because
// the backlog is ordered by fund weight, that batch sat at the head of EVERY run.
console.log('\nfetchWithIsolation — a bad symbol costs only itself')
{
  const far = Date.now() + 60_000
  const path = (syms: string[]) => `/p?symbol=${syms.join(',')}`

  // The healthy case must cost exactly ONE call — isolation is for failures only.
  let calls = 0
  const ok = await fetchWithIsolation(
    async (_p) => { calls++; return [{ symbol: 'A' }, { symbol: 'B' }] },
    path, ['A', 'B'], 5_000, far,
  )
  check(calls === 1, 'a healthy batch makes exactly one request', `made ${calls}`)
  check(ok.rows.length === 2 && ok.dead.length === 0 && ok.error === null, 'and reports no failure')

  // One poison symbol: the other nineteen must still come back, and only the bad one is blamed.
  const bad = 'BRK/B'
  const isolated = await fetchWithIsolation(
    async (p: string) => {
      if (p.includes(encodeURIComponent(bad)) || p.includes(bad)) throw new Error('openbb 400')
      return [{ symbol: p.split('=')[1] }]
    },
    (syms) => `/p?symbol=${symbolList(syms)}`,
    ['GOOD1', bad, 'GOOD2'], 5_000, far,
  )
  check(isolated.rows.length === 2, 'the good symbols still return', `got ${isolated.rows.length}`)
  check(isolated.dead.length === 1 && isolated.dead[0] === bad,
    'only the failing symbol is marked dead', JSON.stringify(isolated.dead))
  check(isolated.error !== null, 'the original batch error is still reported')

  // EVERY symbol failing is an OUTAGE, not twenty bad symbols. Draining aggressively tripped
  // yfinance's rate limit and this negative-cached 1,369 securities for 30 days — including HTHT
  // and LEGN, ordinary Nasdaq tickers — while reporting `classified: 0, noIndustry: 200`, which
  // reads as healthy progress.
  const outage = await fetchWithIsolation(
    async () => { throw new Error('openbb 400') },
    path, ['A', 'B', 'C'], 5_000, far,
  )
  check(outage.dead.length === 0,
    'when NOTHING answers, no symbol is blamed', JSON.stringify(outage.dead))
  check((outage.error ?? '').includes('provider outage'),
    'and the reason says so, so the tally is not read as progress')

  // Out of budget: untried symbols must NOT be recorded as unanswerable. Negative-caching a symbol
  // we never asked about is how a backlog loses work permanently.
  const expired = await fetchWithIsolation(
    async () => { throw new Error('openbb 400') },
    path, ['A', 'B', 'C'], 5_000, Date.now() - 1,
  )
  check(expired.dead.length === 0, 'a blown deadline blames nobody', JSON.stringify(expired.dead))
}

// ── an ISIN hit must be on the security's HOME market ────────────────────────
// Yahoo's ISIN index is inconsistent: Televisa's returns the local TLEVISACPO.MX, Walmex's returns
// ONLY a Frankfurt line. Taking the first hit would price a Mexican retailer off a thin,
// differently-denominated German listing — the mistake `exchanges.ts` exists to prevent.
const VENUES = venuesFromRows([
  { exch_code: 'US', country_iso2: 'US', suffix: '' },
  { exch_code: 'MM', country_iso2: 'MX', suffix: '.MX' },
  { exch_code: 'LN', country_iso2: 'GB', suffix: '.L' },
  { exch_code: 'HK', country_iso2: 'HK', suffix: '.HK' },
  { exch_code: 'KS', country_iso2: 'KR', suffix: '.KS' },
  { exch_code: 'KQ', country_iso2: 'KR', suffix: '.KQ' },
])

console.log('\nvenuesFromRows — the catalog shape')
check(VENUES.KR?.length === 2, 'a country can have several venues', `${VENUES.KR?.length}`)
check(VENUES.KR?.[0].figi === 'KS', 'row order is preserved, so `preference` decides the primary board')
check(VENUES.US?.[0].suffix === '', 'the US suffix is an empty string, not absent')
check(venuesFromRows([{ exch_code: 'XX', country_iso2: null, suffix: '.XX' }]).XX === undefined,
  'a venue with no country is skipped rather than keyed on null')
check(hasLocalExchange('KR', VENUES) && !hasLocalExchange('US', VENUES),
  'US is not a LOCAL exchange — it is the fallback the whole mechanism exists to avoid')
check(pickLocalSymbol('KR', [{ ticker: '000660', exchCode: 'KQ' }, { ticker: '005930', exchCode: 'KS' }], VENUES)?.symbol === '005930.KS',
  'the preferred board wins even when the other is listed first')

console.log('\npickHomeListing — the home market or nothing')
check(pickHomeListing([{ symbol: 'TLEVISACPO.MX', quoteType: 'EQUITY' }], 'MX', VENUES) === 'TLEVISACPO.MX',
  'the local listing is accepted')
check(pickHomeListing([{ symbol: '4GNB.F', quoteType: 'EQUITY' }], 'MX', VENUES) === null,
  'a FOREIGN cross-listing is refused, not taken as a fallback')
check(pickHomeListing(
  [{ symbol: '4GNB.F', quoteType: 'EQUITY' }, { symbol: 'WALMEX.MX', quoteType: 'EQUITY' }], 'MX', VENUES,
) === 'WALMEX.MX', 'the home listing wins even when a foreign one comes first')
check(pickHomeListing([{ symbol: 'BRK-B', quoteType: 'EQUITY' }], 'US', VENUES) === 'BRK-B',
  'a US symbol has no suffix at all')
check(pickHomeListing([{ symbol: 'BRK-B.MX', quoteType: 'EQUITY' }], 'US', VENUES) === null,
  'and a suffixed symbol is therefore NOT a US listing')
check(pickHomeListing([{ symbol: 'RR.L', quoteType: 'EQUITY' }], 'GB', VENUES) === 'RR.L',
  'the UK suffix is accepted')
check(pickHomeListing([{ symbol: 'BRKW', quoteType: 'ETF' }], 'US', VENUES) === null,
  'an ETF written on the name is refused — q=BRK/B returns four of them')
check(pickHomeListing([{ symbol: '0006.HK', quoteType: 'EQUITY' }], 'HK', VENUES) === '0006.HK',
  'Hong Kong four-digit padding survives the suffix match')
check(pickHomeListing([], 'GB', VENUES) === null, 'no hits means no symbol')
check(pickHomeListing([{ symbol: 'AAA.XX', quoteType: 'EQUITY' }], 'ZZ', VENUES) === null,
  'a country with no known venue resolves to nothing rather than guessing')

// ── every resource the cron calls must be one the function ACCEPTS ───────────
// Adding a resource means touching TWO places: the handler block, and the `EXTRA` allow-list the
// request is validated against. Shipped 2026-08-12 with only the first — the handler was there, the
// migration was there, the warm-up cron called it, and the function answered
// `unknown resource 'security-yahoo-symbols'` with a 400. Nothing caught it: the constant IS
// referenced (by the guard), so `deno check` is happy, and no test connects the two lists.
//
// Read as TEXT on purpose. The names live in three files that cannot import each other — a YAML
// workflow, a Deno handler and a shell loop — so the only thing they share is the string.
console.log('\nresource registry — the cron and the function agree')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  const warmup = await Deno.readTextFile(
    new URL('../../../../.github/workflows/market-warmup.yml', import.meta.url),
  )

  // The names the cron POSTs, from the `RESOURCES=$(printf ...)` block.
  const block = warmup.match(/RESOURCES=\$\(printf[\s\S]*?\)\n/)?.[0] ?? ''
  const cronResources = [...block.matchAll(/^\s{10,}([a-z][a-z-]+)\s*\\?$/gm)].map((m) => m[1])
  check(cronResources.length > 10, 'found the cron resource list', `${cronResources.length} names`)

  // What the function will accept: `RESOURCES` keys in resources.ts plus the EXTRA allow-list.
  const resourcesFile = await Deno.readTextFile(new URL('./resources.ts', import.meta.url))
  const declared = new Set<string>([
    ...[...resourcesFile.matchAll(/^\s{2}'([a-z][a-z-]+)':\s*\{/gm)].map((m) => m[1]),
    ...[...index.matchAll(/_RESOURCE = '([a-z][a-z-]+)'/g)].map((m) => m[1]),
  ])
  const extraBlock = index.match(/const EXTRA = \[[\s\S]*?\]/)?.[0] ?? ''
  const accepted = new Set<string>(
    [...declared].filter((name) => {
      const constName = [...index.matchAll(/(\w+_RESOURCE) = '([a-z][a-z-]+)'/g)]
        .find((m) => m[2] === name)?.[1]
      // A resource is reachable if it is a declared RESOURCES entry, or its constant is in EXTRA.
      return !constName || extraBlock.includes(constName)
    }),
  )

  const unreachable = cronResources.filter((r) => !accepted.has(r))
  check(unreachable.length === 0,
    'every resource the warm-up calls is accepted by the function',
    unreachable.length ? `unreachable: ${unreachable.join(', ')}` : '')
}

console.log(failures === 0 ? '\nALL LOGIC CHECKS PASSED' : `\n${failures} LOGIC CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
