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
  planPriceFetches,
  type Bar,
} from './resources.ts'
import { pickHomeListing, type YahooHit } from './yahoo.ts'
import { venuesFromRows, hasLocalExchange, pickLocalSymbol, venueForSymbol } from './exchanges.ts'

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
// ── a dead instrument must not report a live return ──────────────────────────
// Shipped: Egypt, Nigeria and Portugal each showed +0.0% on EVERY period, dated today, from ETFs
// that stopped trading years ago. The provider keeps serving the final bars, so each period is
// measured between two identical closes.
console.log('\nreturnsFor — a stale series reports nothing, not zero')
{
  const now = new Date('2026-08-13T00:00:00Z')
  const dead: Bar[] = [
    { date: '2024-03-28', close: 12.5 },
    { date: '2024-04-01', close: 12.5 },
  ]
  check(Object.keys(returnsFor(dead, now)).length === 0,
    'a series that ends years ago yields NO periods', JSON.stringify(returnsFor(dead, now)))
  check(!Object.values(returnsFor(dead, now)).includes(0),
    'and specifically never the +0.0% that reads as "the market was flat"')

  // The boundary: a long weekend plus holidays is legitimate and must still report.
  const stale = [
    { date: '2026-08-01', close: 100 },
    { date: '2026-08-06', close: 110 },
  ]
  check(Object.keys(returnsFor(stale, now)).length > 0,
    'a 7-day gap still reports — markets close for holidays', JSON.stringify(returnsFor(stale, now)))
}

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

  // A THROTTLE IS STATED, NOT INFERRED — and it is the case the count rule cannot see.
  //
  // The count rule only fires when NOTHING in a batch answers. yfinance throttles progressively, so
  // it refuses some symbols while answering others: `rows.length > 0`, the rule stays silent, and
  // the refused ones are recorded as permanently unanswerable. Caused deliberately 2026-08-13 by
  // draining six resources back to back — the message said `YFRateLimitError: Too Many Requests`
  // the whole time and nothing was reading it, which is how this costs 1,369 negative-cached
  // securities while every count looks like healthy progress.
  const RATE_LIMITED =
    'openbb 400: {"detail":"Error getting data for WK -> YFRateLimitError: Too Many Requests."}'
  const partialThrottle = await fetchWithIsolation(
    async (p: string) => {
      // The BATCH carries the rate-limit message — that is how the provider actually reports it,
      // measured: `openbb 400 on …symbol=GPGI,ITGR,CNK,…: {"detail":"… -> YFRateLimitError …"}`.
      // Isolation then retries one at a time and some still get through, which is what makes the
      // count rule blind to this: `rows.length > 0`, so it never fires.
      if (p.includes(',')) throw new Error(RATE_LIMITED)
      if (p.includes('GOOD')) return [{ symbol: 'GOOD' }]
      throw new Error(RATE_LIMITED)
    },
    path, ['GOOD', 'RATELIMITED'], 5_000, far,
  )
  check(partialThrottle.dead.length === 0,
    'a rate-limited symbol is NOT blamed even when others answered',
    JSON.stringify(partialThrottle.dead))
  check((partialThrottle.error ?? '').includes('RATE-LIMITING'),
    'and the reason names the rate limit, not the symbol')
  check(partialThrottle.rows.length === 1, 'while the symbols that did answer are kept')

  // Out of budget: untried symbols must NOT be recorded as unanswerable. Negative-caching a symbol
  // we never asked about is how a backlog loses work permanently.
  const expired = await fetchWithIsolation(
    async () => { throw new Error('openbb 400') },
    path, ['A', 'B', 'C'], 5_000, Date.now() - 1,
  )
  check(expired.dead.length === 0, 'a blown deadline blames nobody', JSON.stringify(expired.dead))
}

// ── a window that never moved is not a 0.00% return ──────────────────────────
// Found by the flat-return tripwire firing at 32 rows (threshold 5) on 2026-08-13. The cause was
// not delisting, which is what that tripwire was written for: `GOTO.JK` had 62 bars across the
// 3-month window and ONE distinct close — 50, every trading day — and `AOT-R.BK` had 65 bars and
// two. Ordinary listings on live exchanges, padded rather than quoted.
//
// No existing guard could see it. The closes are positive, so `barFrom` accepts them; the latest
// bar is today, so the staleness rule passes; there is no discontinuity, so `firstComparableIndex`
// has nothing to cut. It renders as "this market was flat" — a claim about the market rather than
// an admission that we have no prices for it.
console.log('\nreturnsFor — a constant window reports nothing, not zero')
{
  const day = (n: number) => new Date(Date.UTC(2026, 7, 13) - n * 86_400_000).toISOString().slice(0, 10)
  const now = new Date(Date.UTC(2026, 7, 13))

  // 200 sessions all at exactly 50 — the GOTO.JK shape.
  const frozen: Bar[] = Array.from({ length: 200 }, (_, i) => ({ date: day(199 - i), close: 50 }))
  const f = returnsFor(frozen, now)
  check(f['3m'] === undefined, 'a window with one distinct close reports NO 3m', JSON.stringify(f['3m']))
  check(f['1y'] === undefined, 'and no 1y')

  // Flat for the recent quarter, but genuinely up over the year: the short window must go and the
  // long one must survive. Per-window, because a security can be flat for a week and not for a year.
  // 420 sessions so the 1y anchor actually EXISTS — at 300 the year was omitted for want of a bar
  // that old, which passes the assertion for entirely the wrong reason.
  const mixed: Bar[] = Array.from({ length: 420 }, (_, i) => ({
    date: day(419 - i),
    close: i < 320 ? 10 + i * 0.1 : 42,
  }))
  const m = returnsFor(mixed, now)
  check(m['3m'] === undefined, 'a flat recent quarter still reports no 3m', JSON.stringify(m['3m']))
  check(typeof m['1y'] === 'number' && m['1y'] > 0,
    'while the year, which did move, is still reported', JSON.stringify(m['1y']))
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

console.log('\nvenueForSymbol — the suffix names the venue')
check(venueForSymbol('005930.KS', VENUES) === 'KS', 'a local suffix resolves')
check(venueForSymbol('AAPL', VENUES) === 'US', 'no suffix means US')
check(venueForSymbol('BRK-B', VENUES) === 'US', 'a hyphenated US class share is still US')
check(venueForSymbol('FOO.XYZ', VENUES) === null, 'an unknown suffix resolves to nothing, not a guess')
// Mirrors migration 38's `order by length(suffix) desc, preference`. Stated in two languages, so
// both get asserted rather than trusted to agree.
check(venueForSymbol('SOME.KQ', VENUES) === 'KQ', 'the secondary board is distinguishable from the primary')

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
// ── a throw and an empty answer must not share a branch ──────────────────────
// FIFTH instance of this shape, which is why it is asserted against the SOURCE rather than left to
// review: `figi_missing_at`, `security-fundamentals`, `security-industries`, the isolation
// empty-branch, and then `security-profiles` — where the two were merged behind a comment claiming
// they were "indistinguishable". They never are: the throw sets a flag, and OpenBB answers 204 NO
// CONTENT when a provider genuinely has nothing.
//
// Merging them costs a backlog. An unanswerable batch is counted failed AND skips its
// negative-cache write, so it returns every run forever; then the "all batches failed" guard fails
// the whole resource at exactly the moment the answerable work is done. Measured 2026-08-13:
// `pending_profile` fell 2,665 -> 2,437 and froze, while three sibling resources on the SAME
// endpoint reported ok.
//
// A behavioural test cannot reach this — the decision is inline in a 200-line resource handler with
// a live Supabase client. The shape is what recurs, so the shape is what is checked.
console.log('\nbatch outcomes — a failure and an empty answer are different branches')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  // `somethingFailed || rows.length === 0` — a throw flag OR'd with an empty result.
  const merged = [...index.matchAll(/\w*[Ff]ailed\s*\|\|\s*\w+\.length === 0/g)].map((m) => m[0])
  check(merged.length === 0,
    'no branch ORs a failure flag with an empty result',
    merged.length ? merged.join('; ') : 'none')
}

// ── marking on an empty answer must be EARNED ────────────────────────────────
// An empty answer is a legitimate "no data for these" — until the endpoint stops answering at all,
// when it becomes "no data for anyone" and the same branch records a provider hiccup as hundreds of
// permanently unanswerable securities.
//
// Measured 2026-08-13: draining hard enough to trip yfinance's rate limit made it return
// 200-with-no-rows instead of erroring, so `fetchWithIsolation`'s outage rule — which only sees
// THROWS — never fired, and `security-industries` marked 1,414 securities as having no industry.
// Among them INTC, PEP, XOM, TXN, EA and SCCO. The backlog went to zero and looked drained.
//
// So every `rows.length === 0` branch that writes a `*_missing_at` must gate on a success counter
// proving the endpoint answered for someone in this run. Checked against the source because there
// are three such branches in three different resources and the last two rounds of this were fixed
// one call site at a time.
console.log('\nempty-answer marking — gated on the endpoint having answered')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))

  // WHY A LIST OF EXACT GATES rather than an analysis of the branches.
  //
  // The first version of this check walked from each `… .length === 0` branch to its closing brace
  // and asked whether a gate appeared inside. It caught ONE of four deleted gates when tested by
  // mutation: brace depth counted braces in comments and template literals too, so most blocks
  // ended early and the write fell outside the window — the check reported "all six marking sites
  // gated" while three were not. It would have shipped as protection while protecting nothing,
  // which is the failure mode this whole file exists to prevent.
  //
  // A named list is brittle to refactoring and that is the acceptable trade: rewording a gate fails
  // here loudly and the list gets updated, whereas DELETING one — the thing that costs thousands of
  // securities — can never pass silently.
  //
  // Each entry is a site where a batch that produced nothing writes a `*_missing_at`, and the
  // string is the proof that the endpoint answered for someone in this run.
  const gates: [string, string][] = [
    ['security-statements',   'anyAnswer || (failed === 0 && written > 0)'],
    ['security-industries',   'stillUnrecorded.length > 0 && classified > 0'],
    ['security-profiles',     'if (classified > 0) {'],
    ['security-fundamentals', 'if (written > 0) {'],
  ]
  for (const [resource, gate] of gates) {
    check(index.includes(gate), `${resource} still gates its empty-answer marking`, gate)
  }

  // `security-performance` is held to a STRICTER rule than the five above, so it is asserted
  // separately rather than by its old gate string.
  //
  // Those five gate on "the endpoint answered for SOMEONE in this run", which is a tally — and a
  // tally is exactly what yfinance defeats. It throttles PROGRESSIVELY: some symbols in a batch
  // come back, others are simply absent from the same 200, and nothing throws. Measured
  // 2026-08-14, that had left 2,548 securities negative-cached while the provider was serving
  // daily bars for every one of them (MediaTek, Tapestry, Ferguson, ACS), 2,297 of them marked in
  // a single pass. So marking now requires the symbol to have been asked ON ITS OWN.
  //
  // Two things must remain true, and deleting either is the failure this file exists to catch:
  // the marked set comes from `confirmedDead` (per-symbol evidence, not batch arithmetic), and a
  // mark RETRACTS the rows it can no longer stand behind — otherwise the stale number outlives
  // the fix, which is how 1d/1w/1m = 0.00% survived four days behind a mark.
  // `security-prices` is held to the same stricter rule, and for the same reason: `written > 0`
  // kills a backlog the moment its answerable work is done. Measured 2026-08-14 —
  // `written: 0, emptySeries: 300, batchesFailed: 0, remaining: 393`, unchanged run after run,
  // because every security left is one yfinance does not carry (ICT.PS and FAB.AE return
  // "not covered"). Nothing was wrongly marked; the same 300 were simply re-asked eight times a
  // day for ever. Fourth instance of this shape in this file's history.
  // PAGING MUST BE A PARTITION, NOT FOUR SAMPLES. Both multi-page backlog reads order by
  // `best_weight`, which is 0 for every security no tracked fund holds — most of the rows. Postgres
  // gives no stable order among ties, so successive `range()` calls can return one row twice and
  // another never. Found 2026-08-14 by making the same mistake in an audit query: paging
  // `security_current` without an order reported 1,935 duplicated company names and repeated ISINs,
  // all of which vanished under `order=security_id` — 12,000 rows, 12,000 distinct ids, 0 repeats.
  // The data was fine; the query was not. The resources had the same shape.
  // AN EARLY RETURN AFTER THE CLAIM MUST GIVE IT BACK. `begin_refresh` takes the lock before any
  // per-resource validation runs, so a `return json({error}, 400)` below it leaves `refresh_log`
  // with `finished_at: null` and refuses the resource for the whole in-flight TTL. Measured
  // 2026-08-15: a `promote-listing` call with no `figi` answered 400, and the next VALID call 45
  // seconds later was refused `{ skipped: true, reason: 'fresh or in flight' }`. It self-heals in
  // two minutes, so it is a short self-inflicted outage rather than a stuck resource — but it is
  // triggered by the already-malformed request, so one mistake costs two failures. Counted rather
  // than named, so a new validation path cannot be added without releasing.
  const validationReturns = index.match(/return json\(\{ error: '[^']*needs a/g)?.length ?? 0
  check(validationReturns === 0,
    'no post-claim validation returns without releasing the lock',
    validationReturns ? `${validationReturns} early return(s) still hold the claim` : 'all release')

  // AN ACTION MUST RECORD THE LISTING IT WAS SEEN ON. Tiingo is asked by US ticker; `security_price`
  // stores the PRIMARY listing; those differed for 33 of the first 45 securities ingested
  // (SSNLF vs 005930.KS, NONOF vs NOVO-B.CO, ASMLF vs ASML.AS). A dividend from the OTC line is in
  // USD against a KRW series — wrong by three orders of magnitude — and unverifiable after the fact
  // without this column, which is how it survived a full review and a green suite.
  check(index.includes('observed_symbol: item.symbol'),
    'a corporate action records the listing it was observed on',
    'observed_symbol')

  // A SPLIT FACTOR IS A FLOAT, so "no split" is not `=== 1`. Tiingo returns a 3-for-1 as
  // 3.0000000001 often enough to matter, and the inverse — comparing with `!==` — would record a
  // split on every ordinary bar of every security, which is 3 million phantom rows.
  const tiingo = await Deno.readTextFile(new URL('./tiingo.ts', import.meta.url))
  check(/Math\.abs\(factor - 1\) > 1e-9/.test(tiingo),
    'splitFactor is compared with a tolerance, not for exact equality',
    'Math.abs(factor - 1) > 1e-9')
  // A 404 from Tiingo is a FACT about the symbol (it does not carry local foreign listings), and a
  // 500 is not. Collapsing them is the throw-vs-empty shape that has cost this pipeline thousands
  // of securities; the typed error is what keeps the marking path narrow.
  check(tiingo.includes('export class TiingoNoSuchTicker'),
    'a Tiingo 404 is a distinct, typed outcome — not a generic failure',
    'TiingoNoSuchTicker')
  check(index.includes('e instanceof TiingoNoSuchTicker'),
    'and only that outcome marks the security',
    'instanceof check at the marking site')

  // A BACKLOG'S `remaining` MUST BE IN THE SAME UNIT AS WHAT IT COUNTS DOWN FROM. The first live
  // run of `security-corporate-actions` reported `remaining: 0` on 60 securities that had barely
  // been touched, because `written` counts ACTION ROWS (521 of them) and `wanted.length` counts
  // SECURITIES — the subtraction went negative and clamped. A drained backlog and a refused one
  // looked identical, which is the failure this whole file exists to prevent.
  check(index.includes('wanted.length - covered - none - noTicker'),
    'corporate-actions remaining counts SECURITIES, not rows',
    'remaining uses `covered`, not `written`')

  const pageOrders = index.match(/\.range\(/g)?.length ?? 0
  const tiebreaks = index.match(/\.order\('security_id', \{ ascending: true \}\)/g)?.length ?? 0
  check(tiebreaks >= pageOrders,
    'every paged backlog read has a UNIQUE sort key, so its pages partition',
    `${pageOrders} range() reads, ${tiebreaks} unique tiebreaks`)

  check(
    index.includes('const ids = emptyIds'),
    'security-prices marks only symbols confirmed ALONE',
    'const ids = emptyIds',
  )
  check(
    index.includes('isolatedWrites += bars.length'),
    'security-prices KEEPS what isolation recovers rather than discarding it',
    'isolatedWrites',
  )
  check(
    index.includes('const missedIds = confirmedDead'),
    'security-performance marks only symbols confirmed ALONE',
    'const missedIds = confirmedDead',
  )
  check(
    index.includes('stale performance retract failed'),
    'security-performance retracts the rows it stops standing behind',
    'stale performance retract failed',
  )
}

// ── an offshore incorporation is not a market ────────────────────────────────
// N-PORT reports the INCORPORATION jurisdiction, so Alibaba is filed under `KY`. There is no
// exchange in the Cayman Islands, so the strict home-market rule refused every hit — including the
// correct one — and the security fell back to OpenFIGI's US lookup: displayed AND priced as `BABAF`
// while its real listing is `9988.HK`. 180 equities sit in venue-less jurisdictions (119 KY, 56 BM,
// 5 VG), none of them drillable.
console.log('\npickHomeListing — a country with no venues still resolves')
{
  const offshore: YahooHit[] = [
    { symbol: 'KYG017191142.SG', quoteType: 'EQUITY' },   // Stuttgart — not in the venue table
    { symbol: '9988.HK', quoteType: 'EQUITY' },           // Hong Kong — the real listing
  ]
  check(pickHomeListing(offshore, 'KY', VENUES) === '9988.HK',
    'a Cayman-filed security resolves to its real exchange',
    String(pickHomeListing(offshore, 'KY', VENUES)))

  // The strict rule must still hold where the country DOES name markets, or a Korean bank gets
  // priced off its Frankfurt line — the mistake `exchanges.ts` exists to prevent.
  const korean: YahooHit[] = [
    { symbol: 'KRX.F', quoteType: 'EQUITY' },             // Frankfurt
    { symbol: '005930.KS', quoteType: 'EQUITY' },         // Seoul
  ]
  check(pickHomeListing(korean, 'KR', VENUES) === '005930.KS',
    'a country WITH venues still requires one of its own',
    String(pickHomeListing(korean, 'KR', VENUES)))
  check(pickHomeListing([{ symbol: 'KRX.F', quoteType: 'EQUITY' }], 'KR', VENUES) === null,
    'and refuses a foreign cross-listing rather than taking it')
}

console.log('\nresource registry — the cron and the function agree')
{
  const index = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  const warmup = await Deno.readTextFile(
    new URL('../../../../.github/workflows/market-warmup.yml', import.meta.url),
  )

  // The names the cron POSTs, from the `RESOURCES=$(printf ...)` block.
  const block = warmup.match(/RESOURCES=\$\(printf[\s\S]*?\)\n/)?.[0] ?? ''
  // The trailing `)` is not optional decoration — the LAST entry in the list ends with it instead
  // of a line-continuation `\`, so a pattern that only allows `\` silently drops one resource. It
  // dropped `derive-classifications`, which meant the check above had never actually verified it.
  // Found by the scheduling check below reporting it as unscheduled when it plainly was not.
  const cronResources = [...block.matchAll(/^\s{10,}([a-z][a-z-]+)\s*[\\)]?$/gm)].map((m) => m[1])
  check(cronResources.length > 10, 'found the cron resource list', `${cronResources.length} names`)

  // What the function will accept: `RESOURCES` keys in resources.ts plus the EXTRA allow-list.
  const resourcesFile = await Deno.readTextFile(new URL('./resources.ts', import.meta.url))
  const figi = await Deno.readTextFile(new URL('./figi.ts', import.meta.url))
  const declared = new Set<string>([
    ...[...resourcesFile.matchAll(/^\s{2}'([a-z][a-z-]+)':\s*\{/gm)].map((m) => m[1]),
    ...[...index.matchAll(/_RESOURCE = '([a-z][a-z-]+)'/g)].map((m) => m[1]),
  ])
  // `EXTRA` is DERIVED from the TTL map (`Object.keys`), so the allow-list and the TTL table are
  // the same list and cannot drift. Parse the map.
  const extraBlock = index.match(/const EXTRA_TTL_MINUTES: Record<string, number> = \{[\s\S]*?\n  \}/)?.[0] ?? ''
  check(extraBlock.length > 0, 'found the TTL map that defines the extra resources')
  const accepted = new Set<string>(
    [...declared].filter((name) => {
      const constName = [...index.matchAll(/(\w+_RESOURCE) = '([a-z][a-z-]+)'/g)]
        .find((m) => m[2] === name)?.[1]
      // A resource is reachable if it is a declared RESOURCES entry, or its constant is in EXTRA.
      return !constName || extraBlock.includes(`[${constName}]`)
    }),
  )

  // ── EVERY RESOURCE DECLARES A TTL, AND NOTHING INHERITS ONE ────────────────────────────────
  //
  // This is the guard for the defect measured 2026-08-17. The TTL used to be a ternary chain
  // ending in `: PROFILE_TTL_MINUTES`, kept BESIDE a separate `EXTRA` array of known resources.
  // Three resources were in the array and not in the chain, so they silently inherited SEVEN DAYS
  // — and all three are incremental backlogs that must run every pass:
  // `security-prices` (frozen 08-14 to 08-21 while `pending_prices` grew 2,940 -> 11,348),
  // `security-yahoo-symbols`, `security-corporate-actions`.
  //
  // NOTHING COULD REPORT IT. The cron called them eight times a day and each answered
  // `{"skipped":true,"reason":"fresh or in flight"}`, which is a SUCCESS for a warm-up — green
  // workflow, `ok: true` in `refresh_log`, no error anywhere, and price ingestion stopped dead.
  //
  // Asserted against the SOURCE because it is the SHAPE that recurs: a default that silently
  // supplies a wrong answer is worse than no default, which would have 400'd on the first call.
  const ttlKeys = [...extraBlock.matchAll(/\[(\w+_RESOURCE)\]:\s*(\w+)/g)]
  const withoutTtl = [...index.matchAll(/(\w+_RESOURCE) = '([a-z][a-z-]+)'/g)]
    .map((m) => m[1])
    .filter((c) => !ttlKeys.some(([, key]) => key === c))
  check(withoutTtl.length === 0,
    'every declared resource constant has an explicit TTL',
    withoutTtl.length ? `no TTL declared for: ${withoutTtl.join(', ')}` : '')

  check(!/:\s*PROFILE_TTL_MINUTES\s*$/m.test(index.replace(/\[PROFILE_RESOURCE\]:.*/g, '')),
    'there is no fallback TTL for a resource that declares none')

  // The incremental backlogs specifically. A backlog resource drains a slice per run, so anything
  // longer than the cron interval stalls it for the length of the TTL rather than slowing it.
  const mustBeBacklog = [
    'SEC_PRICES_RESOURCE', 'YAHOO_SYMBOL_RESOURCE', 'ACTIONS_RESOURCE', 'STATEMENTS_RESOURCE',
    'FUNDAMENTALS_RESOURCE', 'INDUSTRY_RESOURCE', 'SEC_PROFILE_RESOURCE', 'SEC_PERF_RESOURCE',
    'LOCAL_SYM_RESOURCE', 'LISTINGS_RESOURCE',
  ]
  const wrongTtl = mustBeBacklog.filter((c) =>
    !ttlKeys.some(([, key, ttl]) => key === c && ttl === 'BACKLOG_TTL_MINUTES'))
  check(wrongTtl.length === 0,
    'every incremental backlog runs on the backlog TTL, not a completion-shaped one',
    wrongTtl.length ? `wrong TTL: ${wrongTtl.join(', ')}` : '')

  // ── `remaining` COUNTS SECURITIES, AND A ROW IS NOT A SECURITY ──────────────────────────────
  //
  // `remaining` is subtracted from a count of SECURITIES (`wanted.length`). Subtract a count of
  // ROWS from it and it goes negative and clamps to zero, so the resource reports a drained
  // backlog on every run while thousands of securities are still pending. It is the one number an
  // operator reads to decide whether a backlog is progressing, and it fails in the believable
  // direction.
  //
  // FIVE instances, four of them found only by measuring production against the reported number:
  //   security-corporate-actions  written=521 rows vs 60 securities   -> fixed in #140
  //   security-statements         written=276 rows vs 60 asked, `pending_statements` 3,646
  //   security-performance        refreshed=2,751 rows (~306 securities), `pending_performance` 6,909
  //   security-prices             reported the PAGE SIZE, which never moves however much it does
  //   security-industries/-profiles  counted `writes` BEFORE `dedupeBy`, so a security in two
  //                               sectors counted twice
  //
  // The discriminator is the upsert's conflict key, which says how many rows a security may have:
  // `security_fundamentals` is keyed on `security_id` alone, so counting its rows IS counting
  // securities and `written` is correct there. `security_taxonomy` is keyed on
  // (security_id, node_id, source_code) and `security_price` on (security_id, date), so counting
  // theirs is not. Rather than re-derive that per site — which is how this survived five times —
  // every other site now counts distinct securities in a Set, and this asserts it.
  // THIS IS A WHITELIST PER RESOURCE, and both of those words were arrived at by watching weaker
  // versions fail:
  //
  // - INFERRING the unit (walk back from `counter += arr.length` to the nearest `onConflict`)
  //   cannot tell whether that upsert is the one that wrote `arr`. It raised three false positives
  //   on counters that are correct — `emptyIds`, `deadIds` and `batch` are arrays of SECURITIES,
  //   so their `.length` IS a security count. A guard that cries wolf on correct code gets deleted.
  //
  // - A BLACKLIST OF COUNTER NAMES cannot express "legal here, illegal there", and that is exactly
  //   the situation: `written` is a security count in security-fundamentals (keyed on `security_id`
  //   alone) and a row count in every other resource. Allow-listing the NAME re-permitted the
  //   original bug — proven by mutation, which put `written` back into the statements expression
  //   and passed. It also could not see `classified`, whose increment had changed shape.
  //
  // So: each resource declares the exact identifiers its `remaining` may mention. Anything else
  // fails, including a NEW name. Brittle to refactoring on purpose — renaming a counter fails
  // loudly and is a two-second fix, while a row count silently replacing a security count is a
  // backlog that reports itself drained for ever.
  const REMAINING_MAY_USE: Record<string, string[]> = {
    ACTIONS_RESOURCE: ['wanted', 'covered', 'none', 'noTicker'],
    STATEMENTS_RESOURCE: ['wanted', 'symbolsAnswered', 'none'],
    // `written` is legitimate here and ONLY here: `security_fundamentals` is keyed on
    // `security_id` alone, so one row is one security.
    FUNDAMENTALS_RESOURCE: ['wanted', 'written', 'missing'],
    LOCAL_SYM_RESOURCE: ['addressable', 'resolvedCount', 'unresolved'],
    SEC_PRICES_RESOURCE: ['wanted', 'securitiesPriced', 'emptySeries'],
    YAHOO_SYMBOL_RESOURCE: ['wanted', 'resolved', 'unresolved', 'failed'],
    INDUSTRY_RESOURCE: ['wanted', 'classifiedSecurities', 'noIndustry'],
    SEC_PROFILE_RESOURCE: ['wanted', 'classifiedSecurities', 'unmapped', 'noProfile'],
    SEC_PERF_RESOURCE: ['symbols', 'symbolsCovered'],
    TICKERS_RESOURCE: ['wanted', 'resolvedCount', 'unresolved'],
  }
  const idxLines = index.split('\n')
  const resourceAt = (line: number): string | null => {
    let owner: string | null = null
    idxLines.forEach((l, i) => {
      const m = l.match(/resource === (\w+_RESOURCE)\)/)
      if (m && i + 1 <= line) owner = m[1]
    })
    return owner
  }
  const offenders: string[] = []
  let checkedExpressions = 0
  idxLines.forEach((l, i) => {
    if (!/^\s*remaining:/.test(l)) return
    checkedExpressions++
    const owner = resourceAt(i + 1)
    const allowed = owner ? REMAINING_MAY_USE[owner] : undefined
    if (!allowed) {
      offenders.push(`line ${i + 1}: no declared identifier list for ${owner ?? 'unknown resource'}`)
      return
    }
    // Base identifiers only — a trailing `.length` / `.size` is a property of one of them, not a
    // separate name, and counting it as one made every line look undeclared.
    const used = [...l.matchAll(/(?<![.\w])([a-z]\w*)\b/gi)]
      .map((m) => m[1])
      .filter((n) => !['remaining', 'Math', 'max'].includes(n))
    const undeclared = [...new Set(used)].filter((n) => !allowed.includes(n))
    if (undeclared.length) {
      offenders.push(`line ${i + 1} (${owner}): undeclared in remaining: ${undeclared.join(', ')}`)
    }
    // AND IT MUST ACTUALLY SUBTRACT THE RUN'S PROGRESS. `security-prices` reported
    // `remaining: wanted.length` — the page it was handed, which is the same number whether the
    // run priced everything or nothing. That is not caught by the whitelist, because the page size
    // is a legitimately declared identifier; the defect is the ABSENCE of the subtraction.
    if (!l.includes(' - ')) {
      offenders.push(`line ${i + 1} (${owner}): remaining subtracts nothing — it reports the page size`)
    }
  })
  check(offenders.length === 0,
    'every `remaining` uses only the identifiers its resource declares (rows are not securities)',
    offenders.join(' | '))
  check(checkedExpressions === Object.keys(REMAINING_MAY_USE).length,
    'every declared resource was actually checked — the list has not rotted',
    `${checkedExpressions} expressions vs ${Object.keys(REMAINING_MAY_USE).length} declared`)

  const unreachable = cronResources.filter((r) => !accepted.has(r))
  check(unreachable.length === 0,
    'every resource the warm-up calls is accepted by the function',
    unreachable.length ? `unreachable: ${unreachable.join(', ')}` : '')

  // AND THE OTHER DIRECTION, WHICH IS THE ONE THAT ACTUALLY FAILED.
  //
  // The check above asks "does everything the cron calls exist?" — it cannot see a resource that
  // exists and is never called. `exchange-listings` was in exactly that state: written, deployed,
  // reachable, and absent from the schedule, so the ONLY thing that grows the universe beyond what
  // the tracked funds happen to hold ran when a human remembered. Measured 2026-08-14: it had last
  // run on 08-11, three days earlier, with **16 venues never enumerated at all** — Australia,
  // Japan, China, Indonesia, Sweden, Greece, Peru — and the US sweep parked on prefix `A`.
  //
  // Nothing reported it. Every backlog it feeds was drained, every count was plausible, and a
  // resource that is never invoked cannot fail. That is the same shape as the inert column in
  // migration 56: the failure is an ABSENCE, and absences do not raise.
  //
  // On-demand resources are named explicitly rather than pattern-matched, so adding one is a
  // deliberate act. `security-refresh` fires when a user opens a stock page; `promote-listing` when
  // an admin pulls a named ticker into the universe. Neither has a backlog to drain, so neither
  // belongs on a timer — everything else does.
  const ON_DEMAND = new Set(['security-refresh', 'promote-listing'])
  const unscheduled = [...accepted].filter((r) => !ON_DEMAND.has(r) && !cronResources.includes(r))
  check(unscheduled.length === 0,
    'every backlog resource is actually SCHEDULED, not merely reachable',
    unscheduled.length ? `never runs on the cron: ${unscheduled.join(', ')}` : '')

  // A REFUSED SWEEP MUST NOT READ AS A FINISHED ONE, and a run that produced nothing must not
  // overwrite what earlier runs recorded. Both were true of `exchange-listings` until 2026-08-14:
  // OpenFIGI answered 429 on the first page, `listExchange` broke out silently, and the resource
  // returned `written: 0, pages: 0, complete: false` with `ok: true` — while writing that zero over
  // Japan's recorded 1,800.
  //
  // Asserted on the source because there is no way to reach it behaviourally: it needs OpenFIGI to
  // rate-limit us on demand.
  check(/if \(res\.status === 429\) \{ throttled = true; break; \}/.test(figi),
    'listExchange REPORTS a 429 rather than breaking silently',
    'throttled = true on 429')
  check(index.includes('...(written > 0 ? { listings: written } : {})'),
    'a run that wrote nothing does not reset the venue count',
    'listings written only when written > 0')
  check(index.includes('throttled: figiThrottled'),
    'the sweep response distinguishes refused from exhausted',
    'throttled is reported')
}

// ── incremental price fetching ───────────────────────────────────────────────
// The provider takes ONE start_date per request, so a batch costs whatever its furthest-behind
// member needs. Mixing a never-priced security with a day-stale one makes the whole batch fetch 400
// days — which would defeat the point of storing the series at all.
console.log('\nplanPriceFetches — a daily refresh should ask for a day')
{
  const now = new Date('2026-08-12T00:00:00Z')
  const plans = planPriceFetches([
    { symbol: 'NEW1', fetchSymbol: 'NEW1', lastDate: null },
    { symbol: 'FRESH', fetchSymbol: 'FRESH.ST', lastDate: '2026-08-11' },
    { symbol: 'STALE', fetchSymbol: 'STALE', lastDate: '2026-08-01' },
  ], now, 10)
  const fullPlan = plans.find((p) => p.symbols.some((s) => s.symbol === 'NEW1'))
  const incPlan = plans.find((p) => p.symbols.some((s) => s.symbol === 'FRESH'))
  check(fullPlan?.startDate.startsWith('2025-') === true,
    'a never-priced security gets the full window',
    fullPlan?.startDate)
  check(incPlan !== undefined && incPlan !== fullPlan,
    'it does NOT drag the incremental ones into a 400-day fetch')
  check(incPlan?.startDate === '2026-08-01',
    'an incremental batch starts at its OLDEST member, not the newest', incPlan?.startDate)
  check(incPlan?.symbols.find((s) => s.symbol === 'FRESH')?.fetchSymbol === 'FRESH.ST',
    'the FETCH symbol is carried separately from the display symbol')

  // A gap wider than the window cannot be closed by appending.
  const ancient = planPriceFetches(
    [{ symbol: 'OLD', fetchSymbol: 'OLD', lastDate: '2019-01-01' }], now, 10)
  check(ancient[0].startDate.startsWith('2025-'),
    'a gap wider than the window refetches the whole window rather than leaving a hole')

  check(planPriceFetches([], now, 10).length === 0, 'an empty backlog plans nothing')
}

console.log(failures === 0 ? '\nALL LOGIC CHECKS PASSED' : `\n${failures} LOGIC CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
