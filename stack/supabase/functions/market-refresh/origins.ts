/**
 * Where each upstream lives — configurable so an HTTP cache can sit in front of it.
 *
 * WHY THIS EXISTS. Re-running a resource after fixing a parser used to mean re-fetching everything
 * from a rate-limited provider. With a caching proxy in front, the same run re-issues the same URLs
 * and is served from disk. Nothing here is cache LOGIC — these are hostnames, exactly as
 * `OPENBB_API_URL` already is (`index.ts`, `openbbFetcher(baseUrl)`). The TTLs, the keys and the
 * eviction all live in the proxy; a caller cannot tell whether it was served from cache.
 *
 * EVERY DEFAULT IS THE REAL ORIGIN, which is what makes the proxy optional: with none of these set
 * the functions talk to the providers directly, exactly as before. That is deliberate — a cache
 * that can take production down when it is removed is not worth having.
 *
 * READ LAZILY, NEVER AT MODULE SCOPE. A top-level `Deno.env.get` executes on import, so a module
 * that merely imports this one would demand `--allow-env` — which `logic-check.ts` deliberately
 * does not grant, because a network-free check that needs permissions to reach a pure parser has
 * defeated its own purpose. `edgar.ts` records the same trap for its User-Agent. These are
 * therefore FUNCTIONS, not consts, and calling one is what reads the environment.
 */

/** One origin, trailing slashes stripped so callers can always template `${origin()}/path`. */
function origin(envVar: string, fallback: string): string {
  const raw = Deno.env.get(envVar)
  return (raw && raw.trim() ? raw.trim() : fallback).replace(/\/+$/, '')
}

/** `www.sec.gov` — bulk files and the EDGAR archives (N-PORT `primary_doc.xml`). */
export const secWww = () => origin('SEC_WWW_BASE_URL', 'https://www.sec.gov')

/** `data.sec.gov` — submissions and the XBRL `companyfacts` API. */
export const secData = () => origin('SEC_DATA_BASE_URL', 'https://data.sec.gov')

/** `efts.sec.gov` — EDGAR full-text search, which is how a fund's filing is found. */
export const secFts = () => origin('SEC_FTS_BASE_URL', 'https://efts.sec.gov')

/** `api.openfigi.com` — ISIN -> ticker. POSTs, so the cache key must include the body. */
export const openFigi = () => origin('OPENFIGI_BASE_URL', 'https://api.openfigi.com')

/** `query2.finance.yahoo.com` — ISIN search and FX chart history. */
export const yahoo = () => origin('YAHOO_BASE_URL', 'https://query2.finance.yahoo.com')

/** `www.alphavantage.co` — historical EPS. 25 calls a DAY, so a cache hit here is worth the most. */
export const alphaVantage = () => origin('ALPHAVANTAGE_BASE_URL', 'https://www.alphavantage.co')

/** `api.tiingo.com` — splits and dividends. */
export const tiingo = () => origin('TIINGO_BASE_URL', 'https://api.tiingo.com')
