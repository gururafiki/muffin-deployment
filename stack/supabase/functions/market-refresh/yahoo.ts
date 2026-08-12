// Resolve a security's provider symbol from its ISIN, using Yahoo's own search.
//
// WHY THIS EXISTS. `security_identifier.kind_code = 'ticker'` comes from OpenFIGI, whose `ticker` is
// the BLOOMBERG spelling, and the price provider does not accept it. Measured 2026-08-12 against
// the provider directly:
//
//   BRK/B        400s        -> BRK-B          Bloomberg class separator
//   RR/.L BP/.L  400s        -> RR.L BP.L      Bloomberg UK form
//   WALMEX*.MX   400s        -> ?              Bloomberg Mexican form
//   6.HK 27.HK   "no data"   -> 0006.HK        Hong Kong pads to FOUR digits
//   ESSITYB.ST   "no data"   -> ESSITY-B.ST    Stockholm share class takes a hyphen
//
// The last two carry no unusual character at all, so no amount of grepping for `*` and `/` finds
// them — which is exactly why this asks a SOURCE instead of applying rules written from memory.
// That instruction exists because a hand-written exchange table silently dropped Taiwan's 534
// securities (see `exchanges.ts`).
//
// Amplified by batching: 2.6% bad symbols poisoned 28% of 20-symbol batches on the real ordering,
// and it worsens as a backlog drains and the unanswerable ones concentrate.

import type { VenueMap } from './exchanges.ts'

export interface YahooHit {
  symbol: string
  exchange?: string
  quoteType?: string
  shortname?: string
}

/**
 * The suffixes a security in `iso2` may legitimately carry, derived from the venue table that
 * already drives symbol construction rather than from a second, drifting copy.
 */
export function allowedSuffixes(iso2: string, venueMap: VenueMap): string[] {
  const venues = venueMap[iso2]
  if (!venues) return []
  return [...new Set(venues.map((v) => v.suffix))]
}

/**
 * Pick the hit that belongs to THIS security's home market, or null.
 *
 * MATCHED ON THE SUFFIX, not on Yahoo's `exchange` code. The suffix table is already in the repo
 * and already verified against the price provider; mapping Yahoo's venue codes (`NYQ`, `MEX`,
 * `FRA`, `STO`…) would be a second table to keep right, authored from memory, for no extra
 * information.
 *
 * REQUIRING THE HOME MARKET IS THE POINT, and it is not theoretical. Yahoo's ISIN index is
 * inconsistent — measured 2026-08-12:
 *
 *   MXP4987V1378 (Televisa) -> TLEVISACPO.MX   the local line, correct
 *   MXP810081010 (Walmex)   -> 4GNB.F          ONLY a Frankfurt listing
 *
 * Taking the first hit would price a Mexican retailer off a thin, differently-denominated German
 * line — the exact mistake `exchanges.ts` was written to prevent ("picking arbitrarily would price
 * a Korean bank off its Frankfurt line"). A wrong symbol is worse than no symbol: it yields a
 * plausible series that is quietly about a different listing.
 */
export function pickHomeListing(hits: YahooHit[], iso2: string, venueMap: VenueMap): string | null {
  const suffixes = allowedSuffixes(iso2, venueMap)
  if (suffixes.length === 0) return null
  for (const hit of hits) {
    // Equities only. An ISIN search readily returns ETFs, warrants and futures written on the name.
    if (hit.quoteType && hit.quoteType !== 'EQUITY') continue
    const symbol = (hit.symbol ?? '').trim()
    if (!symbol) continue
    for (const suffix of suffixes) {
      if (suffix === '') {
        // The US case: no suffix at all. `BRK-B` qualifies, `BRK-B.MX` does not.
        if (!symbol.includes('.')) return symbol
      } else if (symbol.toUpperCase().endsWith(suffix.toUpperCase())) {
        return symbol
      }
    }
  }
  return null
}

/**
 * Ask Yahoo which symbol carries this ISIN.
 *
 * Public and keyless. A `User-Agent` is sent because the endpoint answers differently without one.
 * The timeout is the caller's remaining budget, never a fixed value — a per-call timeout that
 * outlives the worker's deadline is how a rate-limited loop becomes a dead worker rather than a
 * short run.
 */
export async function searchByIsin(isin: string, timeoutMs: number): Promise<YahooHit[]> {
  const url =
    `https://query2.finance.yahoo.com/v1/finance/search?q=${encodeURIComponent(isin)}` +
    `&quotesCount=10&newsCount=0`
  const res = await fetch(url, {
    headers: { 'User-Agent': 'Mozilla/5.0 (compatible; muffin/1.0)', accept: 'application/json' },
    signal: AbortSignal.timeout(timeoutMs),
  })
  if (!res.ok) throw new Error(`yahoo ${res.status} for ${isin}`)
  const body = await res.json()
  const quotes = body?.quotes
  if (!Array.isArray(quotes)) return []
  return quotes as YahooHit[]
}
