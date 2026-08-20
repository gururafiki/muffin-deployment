/**
 * Candidate spellings for a symbol the provider does not recognise.
 *
 * "The provider has no data for this security" is frequently "we asked using the wrong name", and
 * the difference is invisible: both produce an empty response, and the negative cache then hides
 * the security for 30 days. Measured against the deployed openbb-api — the left column is what
 * this pipeline produces, the right what the provider actually wants:
 *
 *   ATCOA.ST    -> 0 bars      ATCO-A.ST  -> 190     Stockholm class shares take a hyphen
 *   6.HK        -> 0 bars      0006.HK    -> 190     Hong Kong tickers are zero-padded to four
 *   BRK/B       -> 0 bars      BRK-B      -> 190     a class slash is a hyphen at yfinance
 *   WALMEX*.MX  -> 0 bars      WALMEX.MX  -> 190     OpenFIGI's Bloomberg star is not part of it
 *   RR/.L       -> 0 bars      RR.L       -> 190     ...and neither is a trailing slash
 *
 * THESE ARE CANDIDATES, NOT CORRECTIONS. The rules are generated liberally and each is VERIFIED
 * against the provider before adoption, because pattern-matching alone rewrites working symbols:
 * `^[A-Z]{3,}[ABCD]\.ST$` matches `SAND.ST` (Sandvik), `ALFA.ST` (Alfa Laval) and `TELIA.ST`,
 * which are complete company names ending in A — "repairing" those breaks three securities to fix
 * one. Only a spelling that comes back with bars is ever written.
 */

/** In priority order; the first candidate that ANSWERS wins. */
export function candidateSymbols(symbol: string): string[] {
  const out: string[] = []
  const add = (s: string) => {
    if (s && s !== symbol && !out.includes(s)) out.push(s)
  }

  // A Bloomberg-style star is symbology, not part of the ticker.
  add(symbol.replace(/\*/g, ''))
  // A class slash becomes a hyphen (BRK/B), and a bare trailing slash just goes (RR/.L).
  add(symbol.replace(/\/(?=[A-Z])/g, '-').replace(/\/(?=\.|$)/g, ''))
  add(symbol.replace(/\//g, ''))

  const dot = symbol.lastIndexOf('.')
  const base = dot > 0 ? symbol.slice(0, dot) : symbol
  const suffix = dot > 0 ? symbol.slice(dot) : ''

  // Hong Kong pads the numeric ticker to four digits: 6.HK is 0006.HK.
  if (suffix === '.HK' && /^\d{1,4}$/.test(base)) add(`${base.padStart(4, '0')}${suffix}`)

  // A Nordic share class takes a hyphen. Generated for any trailing A-D on a base of three or
  // more; `SAND.ST` produces the candidate `SAN-D.ST`, which the provider will simply refuse —
  // which is exactly why the candidate is verified rather than trusted.
  if (['.ST', '.OL', '.CO', '.HE'].includes(suffix) && /^[A-Z]{3,}[ABCD]$/.test(base)) {
    add(`${base.slice(0, -1)}-${base.slice(-1)}${suffix}`)
  }

  return out
}
